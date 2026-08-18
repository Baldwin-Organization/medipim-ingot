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
     * @param list<Claim> $liveClaims
     * @param array<string, array{0: string, 1: string}> $shared a code-set
     * @return list<array<string, array{0: string, 1: string}>> a list of code-sets (the clusters)
     */
    public static function variants(
        array $liveClaims,
        array $shared = [],
        bool $guard = true,
        ?callable $uniqueScheme = null,
        array $trustedSources = ['steward'],
        ?callable $barcodeScheme = null,
    ): array
    {
        $sets = [];
        foreach ($liveClaims as $c) {
            if ($c->kind !== 'identity') {
                continue;
            }
            $codeSet = Sets::of($c->data['codes']);
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
                    $claim->kind !== 'identity_evidence'
                    || !in_array($claim->source, $trustedSources, true)
                ) {
                    continue;
                }

                $pair = self::orderedPair($claim->data['left'], $claim->data['right']);
                if ($claim->data['relation'] === 'distinct') {
                    $distinctPairs[self::pairKey(...$pair)] = $pair;
                } elseif ($claim->data['relation'] === 'same') {
                    $samePairs[] = $pair;
                }
            }

            $components = self::guardedComponents(
                $sets,
                $shared,
                $uniqueScheme ?? CodeRegistry::nationalGrade(...),
                $barcodeScheme ?? CodeRegistry::barcodeGrade(...),
                $distinctPairs,
                $samePairs,
            );
        } else {
            $components = self::connectedComponents($sets, $shared);
        }

        // Precompute each component's min — Sets::min sorts the whole set per call, so a
        // comparator computing it per comparison is O(k log k · set sort) instead of once each.
        $paired = [];
        foreach ($components as $c) {
            $paired[] = [Sets::min($c), $c];
        }
        usort($paired, static fn (array $a, array $b): int => Sets::compareCodes($a[0], $b[0]));

        return array_column($paired, 1);
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
        callable $barcodeScheme,
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
            as [$_kind, $bridge, $left, $right, $override]
        ) {
            $leftRoot = self::root($parent, $left);
            $rightRoot = self::root($parent, $right);
            if ($leftRoot === $rightRoot) {
                continue;
            }

            $leftCodes = $codes[$leftRoot];
            $rightCodes = $codes[$rightRoot];
            $merged = Sets::union($leftCodes, $rightCodes);
            if (
                self::distinctConflict($merged, $distinctPairs)
                || (!$override && (
                    self::uniqueConflict($merged, $uniqueScheme, $allowedPairs)
                    || self::reassignableBridge($bridge, $leftCodes, $rightCodes, $barcodeScheme)
                ))
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
        // Signatures sort the set's keys — memoize per set index instead of per comparison.
        $sigs = [];
        $sigOf = static function (int $i) use ($sets, $uniqueScheme, &$sigs): string {
            return $sigs[$i] ??= self::uniqueSignature($sets[$i], $uniqueScheme)."\0".self::codeSignature($sets[$i]);
        };
        foreach ($byCode as $key => $indexes) {
            if (isset($shared[$key])) {
                continue;
            }

            usort($indexes, static fn (int $a, int $b): int => strcmp($sigOf($a), $sigOf($b)));

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
    /**
     * A GS1 barcode is reassignable — NHSBSA publishes a log of GTINs that moved between packs —
     * so it must not be the ONE thing that fuses two components which each already carry an
     * identifier of their own. When either side has nothing but barcodes, the bridge is still the
     * best evidence there is and the join stands.
     *
     * `$bridge` is a code KEY (not a [scheme, value] tuple): the shared code's key for an ordinary
     * edge, or a pair key for an explicit `same` edge. Resolving it against the component gives
     * the tuple back; a pair key resolves to nothing and is not a grade check anyway, since those
     * edges always carry $override.
     *
     * @param array<string, array{0: string, 1: string}> $left
     * @param array<string, array{0: string, 1: string}> $right
     */
    private static function reassignableBridge(string $bridge, array $left, array $right, callable $barcodeScheme): bool
    {
        $code = $left[$bridge] ?? $right[$bridge] ?? null;

        if ($code === null || !$barcodeScheme($code[0])) {
            return false;
        }

        return self::standsAlone($left, $barcodeScheme) && self::standsAlone($right, $barcodeScheme);
    }

    /** @param array<string, array{0: string, 1: string}> $codes */
    private static function standsAlone(array $codes, callable $barcodeScheme): bool
    {
        foreach ($codes as $code) {
            if (!$barcodeScheme($code[0])) {
                return true;
            }
        }

        return false;
    }

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
