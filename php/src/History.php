<?php

declare(strict_types=1);

namespace Ingot;

/**
 * Point-in-time projection — ported from `GoldenRecord.History` (lib/golden_record/history.ex).
 *
 * Project what was known at `knownAt` about the world on `effectiveAt`. Selection happens before
 * identity reconciliation: a late correction changes only queries made after it was recorded.
 * Effective intervals are half-open: `valid_from <= date < valid_to`.
 *
 * Only the legacy branch of `state_bitemporal/3` is ported: the PHP event vocabulary has no
 * `SourceRecordRevised` (the ingest fold does not emit source records — GH #59), so every PHP log
 * takes the branch Elixir calls `legacy_state`. Port `source_record_state` when source records
 * reach this side.
 */
final class History
{
    /**
     * @param list<DomainEvent> $log
     * @return list<GoldenRecord>
     */
    public static function projectBitemporal(array $log, mixed $knownAt, string $effectiveAt, Priority|callable $priority): array
    {
        $known = array_values(array_filter($log, static fn (DomainEvent $e): bool => Bitemporal::known($e, $knownAt)));
        $applicable = array_values(array_filter($known, static fn (DomainEvent $e): bool => Bitemporal::effective($e, $effectiveAt)));

        $claims = [];
        $state = IdentityLedger::new();
        foreach ($applicable as $e) {
            if ($e instanceof Claim) {
                $claims[] = $e;
            }
            $state = IdentityLedger::evolve($state, $e);
        }

        return Catalog::project($state->members, Substrate::current($claims), $priority, self::overridesFrom($applicable));
    }

    /**
     * Both clocks at `$date` — "what did we believe on that day about that day".
     *
     * @param list<DomainEvent> $log
     * @return list<GoldenRecord>
     */
    public static function projectAsOf(array $log, string $date, Priority|callable $priority): array
    {
        return self::projectBitemporal($log, $date, $date, $priority);
    }

    /**
     * Everything known now, effective on `$validDate`.
     *
     * @param list<DomainEvent> $log
     * @return list<GoldenRecord>
     */
    public static function projectValidAsOf(array $log, string $validDate, Priority|callable $priority): array
    {
        return self::projectBitemporal($log, time(), $validDate, $priority);
    }

    /**
     * @param list<DomainEvent> $log
     * @return list<GoldenRecord>
     */
    public static function now(array $log, Priority|callable $priority): array
    {
        return self::projectBitemporal($log, time(), gmdate('Y-m-d'), $priority);
    }

    /**
     * Steward overrides effective in this event set. Attr overrides stay empty pending
     * steward-override support in {@see Catalog::resolveAttributes}.
     *
     * @param list<DomainEvent> $events
     * @return array{attr: array<string,mixed>, product: array<string,mixed>}
     */
    private static function overridesFrom(array $events): array
    {
        $product = [];
        $orders = [];
        foreach ($events as $e) {
            if ($e instanceof ConflictResolved
                && ($e->subject[0] ?? null) === 'collision'
                && is_array($e->decision) && ($e->decision[0] ?? null) === 'product'
            ) {
                $key = $e->subject[1];
                if (!isset($orders[$key]) || ($e->order ?? 0) > $orders[$key]) {
                    $orders[$key] = $e->order ?? 0;
                    $product[$key] = $e->decision[1];
                }
            }
        }

        return ['attr' => [], 'product' => $product];
    }
}
