<?php

declare(strict_types=1);

namespace Ingot;

/**
 * Field survivorship — ported from `Survivorship` in lib/golden_record_core.ex.
 *
 * For each field, the highest-priority source wins; a tie at the top tier among distinct values is
 * `needs_review`. Within a source, the latest claim (by `order`) is the one that counts.
 *
 * `$policy` keeps medipim-specific scoring out of the generic engine, but attribute rankings are
 * ALWAYS applied (no "off" for attributes): a {@see Priority} ranks by tier (back-compat), or a
 * `callable(dimension, source)` is an injected rank function (medipim's per-field/per-org +
 * off-product penalty closes over its context there). The generic engine only consumes the ranks.
 */
final class Survivorship
{
    /**
     * Resolve every attribute field whose anchor code this record's code-set contains.
     *
     * @param array<string, array{0: string, 1: string}> $codes a code-set
     * @param list<Claim> $attrs attribute claims
     * @return list<array{0: string, 1: array<string,mixed>}> sorted [field, decision] pairs is the caller's job
     */
    public static function fieldDecisions(array $codes, array $attrs, Priority|callable $policy): array
    {
        // Group the matching attribute claims by field, preserving first-seen field order.
        /** @var array<string, list<array<string,mixed>>> $byField */
        $byField = [];
        foreach ($attrs as $a) {
            if (!Sets::member($codes, $a->data['code'])) {
                continue;
            }
            $field = $a->data['field'];
            $byField[$field][] = [
                'source' => $a->source,
                'value' => $a->data['value'],
                'order' => $a->order,
            ];
        }

        $out = [];
        foreach ($byField as $field => $entries) {
            $out[] = [$field, self::decide($field, $entries, $policy)];
        }

        return $out;
    }

    /**
     * Decide one dimension from its entries ([{source, value, order}, ...]).
     *
     * @param list<array{source: string, value: mixed, order: int}> $entries
     * @return array{value: mixed, winner: ?string, status: string, candidates: list<array{0: ?string, 1: mixed}>}
     */
    public static function decide(string $dimension, array $entries, Priority|callable $policy): array
    {
        // Latest entry per source (highest order). A null source keys as "" (PHP arrays cannot key
        // on null); the stored entry keeps its real null `source` for fidelity.
        /** @var array<string, array{source: ?string, value: mixed, order: int}> $latestBySource */
        $latestBySource = [];
        foreach ($entries as $e) {
            $src = $e['source'] ?? '';
            $previous = $latestBySource[$src] ?? null;
            if (
                $previous === null
                || $e['order'] > $previous['order']
                || ($e['order'] === $previous['order'] && strcmp(self::valueKey($e['value']), self::valueKey($previous['value'])) > 0)
            ) {
                $latestBySource[$src] = $e;
            }
        }
        // Elixir's `Enum.group_by` builds a small map, which iterates in TERM-SORTED key order —
        // NOT insertion order. So the per-source latest list is ordered by source (nil/null first,
        // then byte-wise). Reproducing this is load-bearing: with all sources tied (no priority),
        // the survivorship winner and candidate order are exactly this source order.
        uksort($latestBySource, self::compareSourceKeys(...));
        $latest = array_values($latestBySource);

        // A Priority (back-compat) or an injected fn(dimension, source): int|float.
        $rank = self::rankFn($policy);

        // Rank first, then source/value as deterministic tie-breaks. An unresolved answer must be
        // byte-identical when the same claims arrive in another order.
        $indexed = [];
        foreach ($latest as $e) {
            $indexed[] = [$rank($dimension, $e['source']), (string) ($e['source'] ?? ''), self::valueKey($e['value']), $e];
        }
        usort($indexed, static function (array $a, array $b): int {
            $r = self::compareRank($a[0], $b[0]);
            if ($r !== 0) {
                return $r;
            }

            $r = strcmp($a[1], $b[1]);

            return $r !== 0 ? $r : strcmp($a[2], $b[2]);
        });
        $ranked = array_map(static fn (array $row): array => $row[3], $indexed);

        $winner = $ranked[0];
        $top = $rank($dimension, $winner['source']);

        // Distinct values among sources tied at the top tier.
        $distinct = [];
        foreach ($latest as $e) {
            if ($rank($dimension, $e['source']) === $top) {
                $distinct[] = $e['value'];
            }
        }
        $distinctUnique = self::uniqueValues($distinct);
        $unresolved = count($distinctUnique) > 1;

        return [
            'value' => $unresolved ? null : $winner['value'],
            'winner' => $unresolved ? null : $winner['source'],
            'status' => $unresolved ? 'needs_review' : 'resolved',
            'candidates' => array_map(
                static fn (array $e): array => [$e['source'], $e['value']],
                $ranked
            ),
        ];
    }

    /**
     * A rank function `(dimension, source): int|float` from the policy: a {@see Priority} ranks by
     * tier; an injected callable carries its own (e.g. medipim per-field/per-org) scoring. Public so
     * any fold step that ranks (e.g. media survivorship) consumes the SAME policy seam — never
     * {@see Priority} directly — so an injected policy threads end-to-end.
     */
    public static function rankFn(Priority|callable $policy): callable
    {
        if ($policy instanceof Priority) {
            return static fn (string $dimension, ?string $source): int|float => $policy->rank($dimension, $source);
        }

        return $policy;
    }

    /**
     * Distinct values preserving order — Elixir's `Enum.uniq` uses term equality, so we compare by
     * a canonical encoding that distinguishes e.g. the int 0 from the string "0" and true from 1.
     *
     * @param list<mixed> $values
     * @return list<mixed>
     */
    private static function uniqueValues(array $values): array
    {
        $seen = [];
        $out = [];
        foreach ($values as $v) {
            $k = self::valueKey($v);
            if (!isset($seen[$k])) {
                $seen[$k] = true;
                $out[] = $v;
            }
        }

        return $out;
    }

    /**
     * Compare two source map-keys the way Elixir orders small-map keys (term order). Sources are
     * strings; a null source is keyed "" by PHP, which sorts first — matching Elixir's nil-first.
     */
    private static function compareSourceKeys(int|string $a, int|string $b): int
    {
        return strcmp((string) $a, (string) $b);
    }

    /** Compare two ranks where INF means "no tier" (sorts last); equal ranks tie. */
    private static function compareRank(int|float $a, int|float $b): int
    {
        return $a <=> $b;
    }

    private static function valueKey(mixed $v): string
    {
        return match (true) {
            is_bool($v) => 'b:'.($v ? '1' : '0'),
            is_int($v) => 'i:'.$v,
            is_float($v) => 'f:'.$v,
            is_string($v) => 's:'.$v,
            $v === null => 'n:',
            default => 'j:'.json_encode($v),
        };
    }
}
