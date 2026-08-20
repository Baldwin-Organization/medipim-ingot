<?php

declare(strict_types=1);

namespace Ingot;

/**
 * Project the re-derived log into golden records — ported from `GoldenRecords`
 * (lib/ingest/golden_records.ex). Folds the members + current claim view via the Date-free
 * `Catalog::project` path, then enriches each variant with its CNK (canonical + aliases).
 */
final class GoldenRecords
{
    /** No steward overrides in the PoC. */
    private const NO_OVERRIDES = ['attr' => [], 'product' => []];

    /**
     * `$priority` is the survivorship policy — a {@see Priority} (tier ranking) OR a
     * `callable(dimension, source): int|float` injected rank fun (medipim's context-aware,
     * off-product-penalty scoring lives there). The toggle is thus reachable from the fold entry,
     * not just {@see Survivorship::decide()}.
     *
     * `$aliases` is the dimension-alias seam (GH #129, {@see DimensionAliases}): an injected
     * old→new field-name map applied to the whole log ONCE, before any fold, so a renamed field
     * folds as one dimension — in this projection AND in every read over the returned log
     * (gr-1y5). Identity claims (schemes, not field names) are untouched, so clustering and CNK
     * enrichment are alias-independent.
     *
     * @param array{log: list<DomainEvent>, ledger: LedgerState} $rederivation
     * @param array<string,string> $aliases
     * @return array{records: list<GoldenRecord>, log: list<DomainEvent>}
     */
    public static function project(array $rederivation, Priority|callable|null $priority = null, array $aliases = []): array
    {
        $priority ??= self::defaultPriority();
        $log = $rederivation['log'];
        $ledger = $rederivation['ledger'];
        if ($aliases !== []) {
            // gr-1y5: aliases apply to the WHOLE log, once, up front — and the normalized log is
            // what we return, so every read over it (Api::get, History::now) folds the same
            // dimensions this projection did. Both spellings then share one slot, last-wins.
            $log = DimensionAliases::normalize($log, $aliases);
            $live = self::liveClaims($log);
        } else {
            $live = $rederivation['live'] ?? self::liveClaims($log);
        }

        $projected = Catalog::project($ledger->members, $live, $priority, self::NO_OVERRIDES);

        // Identity slots are kind-tagged, so filtering the live view equals folding the log's
        // identity claims alone — computed once for every variant's public-id resolution.
        $liveIdentity = [];
        foreach ($live as $c) {
            if ($c->kind === 'identity') {
                $liveIdentity[] = $c;
            }
        }

        $records = [];
        foreach ($projected as $p) {
            $variants = [];
            foreach ($p->variants as $variant) {
                $variants[] = self::enrich($variant, $ledger, $liveIdentity, $priority);
            }
            $records[] = new GoldenRecord($p->product, $variants);
        }

        return ['records' => $records, 'log' => $log];
    }

    /**
     * Convenience: re-derive envelopes at `at`, then project.
     *
     * @param list<Envelope> $envelopes
     * @param array<string,string> $aliases
     * @return array{records: list<GoldenRecord>, log: list<DomainEvent>}
     */
    public static function fromEnvelopes(array $envelopes, mixed $at, Priority|callable|null $priority = null, array $aliases = []): array
    {
        return self::project(Rederivation::run($envelopes, $at), $priority, $aliases);
    }

    /** The permissive default priority — every source unranked, so conflicts tie. */
    public static function defaultPriority(): Priority
    {
        return Priority::new([], []);
    }

    /** @param list<Claim> $liveIdentity */
    private static function enrich(Variant $variant, LedgerState $ledger, array $liveIdentity, Priority|callable $priority): Variant
    {
        return $variant->withCnk(PublicId::canonicalFrom('cnk', $ledger->members[$variant->key] ?? [], $liveIdentity, $priority));
    }

    /**
     * @param list<DomainEvent> $log
     * @return list<Claim>
     */
    private static function liveClaims(array $log): array
    {
        $claims = [];
        foreach ($log as $e) {
            if ($e instanceof Claim) {
                $claims[] = $e;
            }
        }

        return Substrate::current($claims);
    }
}
