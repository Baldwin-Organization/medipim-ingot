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
     * @param array{log: list<DomainEvent>, ledger: LedgerState} $rederivation
     * @return array{records: list<array<string,mixed>>, log: list<DomainEvent>}
     */
    public static function project(array $rederivation, Priority|callable|null $priority = null): array
    {
        $priority ??= self::defaultPriority();
        $log = $rederivation['log'];
        $ledger = $rederivation['ledger'];

        $projected = Catalog::project($ledger->members, self::liveClaims($log), $priority, self::NO_OVERRIDES);

        $records = [];
        foreach ($projected as $p) {
            $variants = [];
            foreach ($p['variants'] as $variant) {
                $variants[] = self::enrich($variant, $log, $priority);
            }
            $records[] = ['product' => $p['product'], 'variants' => $variants];
        }

        return ['records' => $records, 'log' => $log];
    }

    /**
     * Convenience: re-derive envelopes at `at`, then project.
     *
     * @param list<array<string,mixed>> $envelopes
     * @return array{records: list<array<string,mixed>>, log: list<array<string,mixed>>}
     */
    public static function fromEnvelopes(array $envelopes, mixed $at, Priority|callable|null $priority = null): array
    {
        return self::project(Rederivation::run($envelopes, $at), $priority ?? self::defaultPriority());
    }

    /** The permissive default priority — every source unranked, so conflicts tie. */
    public static function defaultPriority(): Priority
    {
        return Priority::new([], []);
    }

    /**
     * @param array<string,mixed> $variant
     * @param list<DomainEvent> $log
     * @return array<string,mixed>
     */
    private static function enrich(array $variant, array $log, Priority|callable $priority): array
    {
        $variant['cnk'] = PublicId::canonical('cnk', $variant['key'], $log, $priority);

        return $variant;
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
