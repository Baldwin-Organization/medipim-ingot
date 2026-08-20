<?php

declare(strict_types=1);

namespace Ingot;

/**
 * The customer read layer — ported from `GoldenRecord.Api` (lib/golden_record/api.ex). Two rules
 * make splits/merges survivable: customers address by CODE (resolved to the current owner), not
 * by surrogate key, and every key carries an identity status so a stale key redirects instead of
 * breaking. `lookup`/`get` answer point-in-time via {@see History::now}.
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
        // Term-sorted key order like Elixir's map iteration — a held conflict can leave one code
        // in two keys' sets, and insertion (minting) order picks a different owner (gr-bf0).
        $members = self::ledger($log)->members;
        ksort($members, SORT_STRING);
        foreach ($members as $k => $codes) {
            if (Sets::member($codes, $canon)) {
                return $k;
            }
        }

        return null;
    }

    /**
     * Identity status of a key: active, merged (forwarding), or split.
     *
     * @param list<DomainEvent> $log
     */
    public static function identityStatus(array $log, string $key): IdentityStatus
    {
        // Merges chain (A->B, then B->C): follow until the survivor; $seen guards odd logs.
        $supersededBy = null;
        $cursor = $key;
        $seen = [$key => true];
        do {
            $next = null;
            foreach ($log as $e) {
                if ($e instanceof IdentitiesMerged
                    && in_array($cursor, $e->from, true) && $cursor !== $e->into
                ) {
                    $next = $e->into;
                    break;
                }
            }
            if ($next === null || isset($seen[$next])) {
                break;
            }
            $seen[$next] = true;
            $supersededBy = $cursor = $next;
        } while (true);

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
            return IdentityStatus::merged($supersededBy);
        }
        if ($splitInto !== null) {
            return IdentityStatus::split($splitInto);
        }

        return IdentityStatus::active();
    }

    /**
     * Customer lookup by code — the robust access pattern. `['ok', record]` with the current
     * record + identity block, or `['not_found', canonicalCode]`.
     *
     * Like the Elixir raw-log lookup, this refolds the ENTIRE log per call (GH #57) — fine at
     * fixture scale; callers fetching many keys prebuild `History::now` and use `getProjected`.
     *
     * @param list<DomainEvent> $log
     * @param array{0: string, 1: string} $code
     * @return array{0: 'ok', 1: array{key: string, identity: IdentityStatus, variant: ?Variant}}|array{0: 'not_found', 1: array{0: string, 1: string}}
     */
    public static function lookup(array $log, array $code, Priority|callable $priority): array
    {
        $key = self::resolveKey($log, $code);
        if ($key === null) {
            return ['not_found', Codes::canonicalize($code)];
        }

        return ['ok', self::get($log, $key, $priority)];
    }

    /**
     * Fetch by surrogate key with its identity status (a stale key still answers, with a redirect).
     *
     * @param list<DomainEvent> $log
     * @return array{key: string, identity: IdentityStatus, variant: ?Variant}
     */
    public static function get(array $log, string $key, Priority|callable $priority): array
    {
        return self::getProjected(History::now($log, $priority), $log, $key);
    }

    /**
     * `get` with the `History::now` projection prebuilt, for callers fetching many keys.
     *
     * @param list<GoldenRecord> $projection
     * @param list<DomainEvent> $log
     * @return array{key: string, identity: IdentityStatus, variant: ?Variant}
     */
    public static function getProjected(array $projection, array $log, string $key): array
    {
        $variant = null;
        foreach ($projection as $record) {
            foreach ($record->variants as $v) {
                if ($v->key === $key) {
                    $variant = $v;
                    break 2;
                }
            }
        }

        return ['key' => $key, 'identity' => self::identityStatus($log, $key), 'variant' => $variant];
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
