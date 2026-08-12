<?php

declare(strict_types=1);

namespace Ingot;

/**
 * Variant clustering — ported from `Cluster` in lib/golden_record_core.ex.
 *
 * Groups identity codes into variant clusters via connected components: two identity code-sets
 * bridge iff they share a NON-shared code. `shared` codes are carried as members but never bridge
 * (a shared GTIN on a bundle and its unit must not fuse them). Clusters come out sorted by their
 * minimum code, so the ledger mints keys deterministically.
 */
final class Cluster
{
    /**
     * @param list<array<string,mixed>> $liveClaims
     * @param array<string, array{0: string, 1: string}> $shared a code-set
     * @return list<array<string, array{0: string, 1: string}>> a list of code-sets (the clusters)
     */
    public static function variants(
        array $liveClaims,
        array $shared = [],
        bool $guard = true,
        ?callable $uniqueScheme = null,
        array $trustedSources = ['steward'],
    ): array
    {
        $sets = [];
        foreach ($liveClaims as $c) {
            if ($c['kind'] !== 'identity') {
                continue;
            }
            $codeSet = Sets::of($c['data']['codes']);
            if ($codeSet === []) {
                continue;
            }
            $sets[] = $codeSet;
        }

        // The same claims must mint the same keys regardless of input order.
        usort($sets, static fn (array $a, array $b): int => strcmp(self::codeSignature($a), self::codeSignature($b)));
        $sets = self::uniqueSets($sets);

        if ($guard) {
            $distinctPairs = [];
            $samePairs = [];
            foreach ($liveClaims as $claim) {
                if (
                    ($claim['kind'] ?? null) !== 'identity_evidence'
                    || !in_array($claim['source'], $trustedSources, true)
                ) {
                    continue;
                }

                $pair = self::orderedPair($claim['data']['left'], $claim['data']['right']);
                if ($claim['data']['relation'] === 'distinct') {
                    $distinctPairs[self::pairKey(...$pair)] = $pair;
                } elseif ($claim['data']['relation'] === 'same') {
                    $samePairs[] = $pair;
                }
            }

            $components = self::guardedComponents(
                $sets,
                $shared,
                $uniqueScheme ?? CodeRegistry::nationalGrade(...),
                $distinctPairs,
                $samePairs,
            );
        } else {
            $components = self::connectedComponents($sets, $shared);
        }

        usort($components, static function (array $a, array $b): int {
            return Sets::compareCodes(Sets::min($a), Sets::min($b));
        });

        return $components;
    }

    /**
     * Build connected components, but hold an edge when its union would introduce a contradictory
     * unique id. Pairs co-asserted by one source record are explicit positive evidence and remain
     * allowed aliases.
     *
     * @param list<array<string, array{0: string, 1: string}>> $sets
     * @param array<string, array{0: string, 1: string}> $shared
     * @return list<array<string, array{0: string, 1: string}>>
     */
    private static function guardedComponents(
        array $sets,
        array $shared,
        callable $uniqueScheme,
        array $distinctPairs,
        array $samePairs,
    ): array
    {
        if ($sets === []) {
            return [];
        }

        $parent = [];
        $codes = [];
        foreach ($sets as $index => $set) {
            $parent[$index] = $index;
            $codes[$index] = $set;
        }
        $allowedPairs = self::allowedUniquePairs($sets, $uniqueScheme);
        foreach ($samePairs as [$left, $right]) {
            $allowedPairs[self::pairKey($left, $right)] = true;
        }

        foreach (
            self::candidateEdges($sets, $shared, $uniqueScheme, $samePairs)
            as [$_kind, $_bridge, $left, $right, $override]
        ) {
            $leftRoot = self::root($parent, $left);
            $rightRoot = self::root($parent, $right);
            if ($leftRoot === $rightRoot) {
                continue;
            }

            $merged = Sets::union($codes[$leftRoot], $codes[$rightRoot]);
            if (
                self::distinctConflict($merged, $distinctPairs)
                || (!$override && self::uniqueConflict($merged, $uniqueScheme, $allowedPairs))
            ) {
                continue;
            }

            $keep = min($leftRoot, $rightRoot);
            $drop = max($leftRoot, $rightRoot);
            $parent[$drop] = $keep;
            $codes[$keep] = $merged;
            unset($codes[$drop]);
        }

        $roots = [];
        foreach (array_keys($parent) as $node) {
            $roots[self::root($parent, $node)] = true;
        }

        $out = [];
        foreach (array_keys($roots) as $root) {
            $out[] = $codes[$root];
        }

        return $out;
    }

    /**
     * @param list<array<string, array{0: string, 1: string}>> $sets
     * @param array<string, array{0: string, 1: string}> $shared
     * @return list<array{0: string, 1: int, 2: int}>
     */
    private static function candidateEdges(
        array $sets,
        array $shared,
        callable $uniqueScheme,
        array $samePairs,
    ): array
    {
        $byCode = [];
        foreach ($sets as $index => $set) {
            foreach ($set as $key => $_code) {
                $byCode[$key][] = $index;
            }
        }

        $edges = [];
        ksort($byCode, SORT_STRING);
        foreach ($byCode as $key => $indexes) {
            if (isset($shared[$key])) {
                continue;
            }

            usort($indexes, static function (int $a, int $b) use ($sets, $uniqueScheme): int {
                $left = self::uniqueSignature($sets[$a], $uniqueScheme)."\0".self::codeSignature($sets[$a]);
                $right = self::uniqueSignature($sets[$b], $uniqueScheme)."\0".self::codeSignature($sets[$b]);

                return strcmp($left, $right);
            });

            for ($i = 0, $n = count($indexes) - 1; $i < $n; ++$i) {
                $edges[] = [0, $key, $indexes[$i], $indexes[$i + 1], false];
            }
        }

        foreach ($samePairs as [$left, $right]) {
            foreach ($byCode[Codes::key($left)] ?? [] as $leftIndex) {
                foreach ($byCode[Codes::key($right)] ?? [] as $rightIndex) {
                    if ($leftIndex !== $rightIndex) {
                        $edges[] = [1, self::pairKey($left, $right), $leftIndex, $rightIndex, true];
                    }
                }
            }
        }

        usort($edges, static fn (array $a, array $b): int => $a <=> $b);

        return $edges;
    }

    /**
     * @param list<array<string, array{0: string, 1: string}>> $sets
     * @return array<string,true>
     */
    private static function allowedUniquePairs(array $sets, callable $uniqueScheme): array
    {
        $allowed = [];
        foreach ($sets as $set) {
            $byScheme = [];
            foreach ($set as $code) {
                if ($uniqueScheme($code[0])) {
                    $byScheme[$code[0]][] = $code;
                }
            }
            foreach ($byScheme as $schemeCodes) {
                usort($schemeCodes, Sets::compareCodes(...));
                foreach (self::pairs($schemeCodes) as [$left, $right]) {
                    $allowed[self::pairKey($left, $right)] = true;
                }
            }
        }

        return $allowed;
    }

    /** @param array<string, array{0: string, 1: string}> $codes */
    private static function uniqueConflict(array $codes, callable $uniqueScheme, array $allowedPairs): bool
    {
        $byScheme = [];
        foreach ($codes as $code) {
            if ($uniqueScheme($code[0])) {
                $byScheme[$code[0]][] = $code;
            }
        }

        foreach ($byScheme as $schemeCodes) {
            usort($schemeCodes, Sets::compareCodes(...));
            foreach (self::pairs($schemeCodes) as [$left, $right]) {
                if (!isset($allowedPairs[self::pairKey($left, $right)])) {
                    return true;
                }
            }
        }

        return false;
    }

    /** @param list<array{0: string, 1: string}> $values */
    private static function pairs(array $values): array
    {
        $out = [];
        for ($left = 0, $n = count($values); $left < $n; ++$left) {
            for ($right = $left + 1; $right < $n; ++$right) {
                $out[] = [$values[$left], $values[$right]];
            }
        }

        return $out;
    }

    private static function pairKey(array $left, array $right): string
    {
        return Codes::key($left)."\x1e".Codes::key($right);
    }

    private static function orderedPair(array $left, array $right): array
    {
        return Sets::compareCodes($left, $right) <= 0 ? [$left, $right] : [$right, $left];
    }

    private static function distinctConflict(array $codes, array $distinctPairs): bool
    {
        foreach ($distinctPairs as [$left, $right]) {
            if (Sets::member($codes, $left) && Sets::member($codes, $right)) {
                return true;
            }
        }

        return false;
    }

    /** @param array<string, array{0: string, 1: string}> $set */
    private static function codeSignature(array $set): string
    {
        $keys = array_keys($set);
        sort($keys, SORT_STRING);

        return implode("\x1f", $keys);
    }

    /** @param array<string, array{0: string, 1: string}> $set */
    private static function uniqueSignature(array $set, callable $uniqueScheme): string
    {
        $keys = [];
        foreach ($set as $key => $code) {
            if ($uniqueScheme($code[0])) {
                $keys[] = $key;
            }
        }
        sort($keys, SORT_STRING);

        return implode("\x1f", $keys);
    }

    /** @param list<array<string, array{0: string, 1: string}>> $sets */
    private static function uniqueSets(array $sets): array
    {
        $seen = [];
        $out = [];
        foreach ($sets as $set) {
            $signature = self::codeSignature($set);
            if (!isset($seen[$signature])) {
                $seen[$signature] = true;
                $out[] = $set;
            }
        }

        return $out;
    }

    /** @param array<int,int> $parent */
    private static function root(array $parent, int $node): int
    {
        while ($parent[$node] !== $node) {
            $node = $parent[$node];
        }

        return $node;
    }

    /**
     * Mirror of the Elixir reduce: for each incoming set, fuse it with every accumulated component
     * it bridges (share a bare — i.e. non-shared — code), leaving the rest disjoint.
     *
     * @param list<array<string, array{0: string, 1: string}>> $sets
     * @param array<string, array{0: string, 1: string}> $shared
     * @return list<array<string, array{0: string, 1: string}>>
     */
    private static function connectedComponents(array $sets, array $shared): array
    {
        $acc = [];
        foreach ($sets as $set) {
            $bareSet = Sets::difference($set, $shared);

            $overlapping = [];
            $disjoint = [];
            foreach ($acc as $comp) {
                if (!Sets::disjoint(Sets::difference($comp, $shared), $bareSet)) {
                    $overlapping[] = $comp;
                } else {
                    $disjoint[] = $comp;
                }
            }

            $merged = $set;
            foreach ($overlapping as $comp) {
                $merged = Sets::union($merged, $comp);
            }

            // Elixir prepends the merged component: [merged | disjoint].
            array_unshift($disjoint, $merged);
            $acc = $disjoint;
        }

        return $acc;
    }
}
