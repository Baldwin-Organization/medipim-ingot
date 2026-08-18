<?php

declare(strict_types=1);

namespace Ingot;

/**
 * Cluster + reconcile into surrogate keys — ported from `Rederivation` (lib/ingest/rederive.ex).
 *
 * Re-derives identity from the codes themselves: builds claims via ClaimMapping, runs the per-lane
 * reconcile, and stamps the identity events to continue after the max claim order. The output `log`
 * = claims ++ identity_events, foldable unchanged by the engine's read layer.
 */
final class Rederivation
{
    /**
     * @param list<array<string,mixed>> $envelopes
     * @return array{log: list<DomainEvent>, ledger: LedgerState, ledgers: array<string, LedgerState>, clusters: list<array<string, array{0: string, 1: string}>>, shared: array<string, array{0: string, 1: string}>}
     */
    public static function run(array $envelopes, mixed $at): array
    {
        return self::fromClaims(ClaimMapping::build($envelopes), $at);
    }

    /**
     * @param array{claims: list<Claim>, shared: array<string, array{0: string, 1: string}>} $built
     * @return array{log: list<DomainEvent>, ledger: LedgerState, ledgers: array<string, LedgerState>, clusters: list<array<string, array{0: string, 1: string}>>, shared: array<string, array{0: string, 1: string}>}
     */
    public static function fromClaims(array $built, mixed $at): array
    {
        $claims = $built['claims'];
        $shared = $built['shared'];

        $live = Substrate::current($claims);

        [$laneEvents, $ledgers] = Lanes::reconcile($live, $shared, Lanes::newLedgers(), $at);
        $identityEvents = self::stamp($laneEvents, $claims);

        $ledger = IdentityLedger::new();
        foreach ($identityEvents as $e) {
            $ledger = IdentityLedger::evolve($ledger, $e);
        }

        $clusters = Cluster::variants(Lanes::identityClaims($live, 'product'), $shared);

        return [
            'log' => array_merge($claims, $identityEvents),
            'ledger' => $ledger,
            'ledgers' => $ledgers,
            'clusters' => $clusters,
            'shared' => $shared,
        ];
    }

    /**
     * Continue the identity events' order after the highest claim order.
     *
     * @param list<DomainEvent> $events
     * @param list<Claim> $claims
     * @return list<DomainEvent>
     */
    private static function stamp(array $events, array $claims): array
    {
        $base = -1;
        foreach ($claims as $c) {
            $base = max($base, $c->order);
        }

        $out = [];
        $order = $base + 1;
        foreach ($events as $event) {
            $out[] = $event->withOrder($order);
            ++$order;
        }

        return $out;
    }
}
