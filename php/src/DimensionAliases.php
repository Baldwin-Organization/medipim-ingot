<?php

declare(strict_types=1);

namespace Ingot;

/**
 * The dimension-alias seam (GH #129) — ported from `GoldenRecord.DimensionAliases`
 * (lib/golden_record/dimension_aliases.ex): an injected old→new field-name map, applied where
 * claims are normalized on the way into a fold, so a source-side field rename does not split one
 * dimension across two.
 *
 * Claims are write-time canonical — stored events keep their historical spelling forever (the
 * audit trail, same posture as medipim's `products_deltas`). Every fold entry that groups by
 * dimension normalizes through {@see normalize()} FIRST, so survivorship sees one dimension
 * regardless of when a claim was written. Backfill fingerprints hash the pre-alias envelope
 * ({@see \Ingot\Storage\ClaimIngest::envelopeFingerprint}), so a rename never invalidates
 * `backfill_seen` markers — a replay stays a no-op.
 *
 * Aliased spots: an attribute claim's `data.field` (including its optional `":locale"` suffix —
 * the alias applies to the field part), and the collection name a `member_of` edge points at
 * (`data.to = [collection, member]`). Identity claims carry code SCHEMES (`cnk:…`), never field
 * names — a field rename must not change a scheme, so identity claims are deliberately not
 * aliased.
 *
 * Chains (a→b, later b→c) resolve transitively to the terminal name. A cycle is a config error;
 * resolution stops after `count($aliases)` hops instead of looping.
 */
final class DimensionAliases
{
    /**
     * Resolve one dimension name through the alias map: transitive, `"field:locale"`-aware (an
     * exact whole-name entry wins over a bare-field entry).
     *
     * @param array<string,string> $aliases
     */
    public static function resolve(array $aliases, string $name): string
    {
        if ($aliases === []) {
            return $name;
        }

        $terminal = self::chase($aliases, $name);
        if ($terminal !== $name) {
            return $terminal;
        }

        $colon = strpos($name, ':');
        if ($colon === false) {
            return $name;
        }

        return self::chase($aliases, substr($name, 0, $colon)).substr($name, $colon);
    }

    /** @param array<string,string> $aliases */
    private static function chase(array $aliases, string $name): string
    {
        // A chain can be at most count($aliases) links long; running out of hops means a cycle — stop.
        for ($hops = count($aliases); $hops > 0 && isset($aliases[$name]); --$hops) {
            $name = $aliases[$name];
        }

        return $name;
    }

    /**
     * Rewrite every dimension-bearing claim in `$events` to its terminal alias. Everything else
     * (identity, grouping, media, non-member_of edges, non-claim events) passes through unchanged.
     *
     * @param list<DomainEvent> $events
     * @param array<string,string> $aliases
     * @return list<DomainEvent>
     */
    public static function normalize(array $events, array $aliases): array
    {
        if ($aliases === []) {
            return $events;
        }

        return array_map(static fn (DomainEvent $e): DomainEvent => self::normalizeOne($e, $aliases), $events);
    }

    /** @param array<string,string> $aliases */
    private static function normalizeOne(DomainEvent $e, array $aliases): DomainEvent
    {
        if (!$e instanceof Claim) {
            return $e;
        }

        $d = $e->data;
        if ($e->kind === 'attribute' && isset($d['field'])) {
            $d['field'] = self::resolve($aliases, (string) $d['field']);
        } elseif ($e->kind === 'edge' && ($d['relation'] ?? null) === 'member_of' && is_array($d['to'] ?? null)) {
            $d['to'][0] = self::resolve($aliases, (string) $d['to'][0]);
        } elseif ($e->kind === 'member_of' && is_array($d['collection'] ?? null)) {
            // A previously persisted log may still carry un-lowered member_of claims (see Substrate).
            $d['collection'][0] = self::resolve($aliases, (string) $d['collection'][0]);
        } else {
            return $e;
        }

        return new Claim($e->source, $e->kind, $d, $e->validFrom, $e->recordedAt, $e->order, $e->validTo);
    }
}
