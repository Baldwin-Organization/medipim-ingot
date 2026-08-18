<?php

declare(strict_types=1);

namespace Ingot;

/**
 * The customer read layer — a MINIMAL port of `Api` (lib/golden_record_core.ex), limited to the
 * Date-free entrypoints the 422156 ingest path exercises: `resolveKey` (code → current owner key),
 * `changesSince` (the identity-event change feed), and `identityStatus`. The full `Api` (lookup/get
 * via History, which needs Date comparisons) is out of scope.
 */
final class Api
{
    /**
     * Resolve any code (canonical or alias) to the surrogate key that currently owns it, or null.
     *
     * @param list<DomainEvent> $log
     * @param array{0: string, 1: string} $code
     */
    public static function resolveKey(array $log, array $code): ?string
    {
        $canon = Codes::canonicalize($code);
        foreach (self::ledger($log)->members as $k => $codes) {
            if (Sets::member($codes, $canon)) {
                return $k;
            }
        }

        return null;
    }

    /**
     * Identity status of a key: ['status' => 'active'|'merged'|'split', ...].
     *
     * @param list<DomainEvent> $log
     * @return array<string,mixed>
     */
    public static function identityStatus(array $log, string $key): array
    {
        $supersededBy = null;
        foreach ($log as $e) {
            if ($e instanceof IdentitiesMerged
                && in_array($key, $e->from, true) && $key !== $e->into
            ) {
                $supersededBy = $e->into;
                break;
            }
        }

        $splitInto = null;
        foreach ($log as $e) {
            if ($e instanceof IdentitySplit && $e->key === $key) {
                $splitInto = [$key];
                foreach ($e->into as [$nk, $_codes]) {
                    $splitInto[] = $nk;
                }
                break;
            }
        }

        if ($supersededBy !== null) {
            return ['status' => 'merged', 'superseded_by' => $supersededBy];
        }
        if ($splitInto !== null) {
            return ['status' => 'split', 'split_into' => $splitInto];
        }

        return ['status' => 'active'];
    }

    /**
     * Change feed: identity events with order > cursor, so customers can repair local copies.
     *
     * @param list<DomainEvent> $log
     * @return list<DomainEvent>
     */
    public static function changesSince(array $log, int $cursor): array
    {
        $out = [];
        foreach ($log as $e) {
            if (self::isIdentityEvent($e) && ($e->order() ?? 0) > $cursor) {
                $out[] = $e;
            }
        }

        return $out;
    }

    private static function isIdentityEvent(DomainEvent $e): bool
    {
        return $e instanceof IdentityMinted
            || $e instanceof IdentityMembersChanged
            || $e instanceof IdentitiesMerged
            || $e instanceof IdentitySplit;
    }

    /**
     * @param list<DomainEvent> $log
     */
    private static function ledger(array $log): LedgerState
    {
        $state = IdentityLedger::new();
        foreach ($log as $e) {
            $state = IdentityLedger::evolve($state, $e);
        }

        return $state;
    }
}
