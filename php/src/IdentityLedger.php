<?php

declare(strict_types=1);

namespace Ingot;

/**
 * Surrogate-key minting + identity reconciliation — ported from `IdentityLedger` in
 * lib/golden_record_core.ex. The gnarliest module: `decide` turns clusters into identity events
 * (mints, splits, merge proposals, member changes) without ever mutating state, and `evolve` folds
 * one event back into the ledger. Established keys are NEVER auto-merged — a bridge across two of
 * them is GATED behind a steward proposal (ConflictFlagged {merge, keys}).
 */
final class IdentityLedger
{
    public static function new(string $prefix = 'SK'): LedgerState
    {
        return new LedgerState([], 1, $prefix);
    }

    /**
     * Decide the identity events for a reconcile request. `$request` is
     * ['reconcile', clusters, shared, at] (a 3-tuple with no shared defaults to the empty set).
     *
     * @param array{0: string, 1: list<array<string, array{0: string, 1: string}>>, 2?: mixed, 3?: mixed} $request
     * @return list<array<string,mixed>>
     */
    public static function decide(LedgerState $state, array $request): array
    {
        // ['reconcile', clusters, at]  -> shared defaults to the empty set.
        if (count($request) === 3) {
            [$tag, $clusters, $at] = $request;
            $shared = [];
        } else {
            [$tag, $clusters, $shared, $at] = $request;
        }
        if ($tag !== 'reconcile') {
            return [];
        }

        $outcome = self::reconcile($state->members, $state->next, $state->prefix, $clusters, $shared);

        return self::buildEvents($state->members, $outcome, $at);
    }

    /**
     * Fold one identity event into the ledger.
     *
     * @param array<string,mixed> $event
     */
    public static function evolve(LedgerState $s, array $event): LedgerState
    {
        switch ($event['type']) {
            case Events::TYPE_IDENTITY_MINTED:
                $members = $s->members;
                $members[$event['key']] = $event['codes'];

                return $s->with($members, max($s->next, self::keyNum($event['key']) + 1));

            case Events::TYPE_IDENTITY_MEMBERS_CHANGED:
                $members = $s->members;
                $members[$event['key']] = $event['codes'];

                return $s->with($members);

            case Events::TYPE_IDENTITIES_MERGED:
                $members = $s->members;
                foreach ($event['from'] as $k) {
                    if ($k !== $event['into']) {
                        unset($members[$k]);
                    }
                }

                return $s->with($members);

            case Events::TYPE_IDENTITY_SPLIT:
                $members = $s->members;
                $members[$event['key']] = $event['kept_codes'];
                $next = $s->next;
                foreach ($event['into'] as [$nk, $codes]) {
                    $members[$nk] = $codes;
                    $next = max($next, self::keyNum($nk) + 1);
                }

                return $s->with($members, $next);

            case Events::TYPE_IDENTITY_RETRACTED:
                $members = $s->members;
                unset($members[$event['key']]);

                return $s->with($members);

            default:
                // ConflictFlagged / MergeProposed / ConflictResolved / ClaimAsserted / LegacyIdAssigned
                return $s;
        }
    }

    /**
     * The reconcile core. Returns
     * ['minted' => list<string>, 'split' => list<[key, into]>, 'proposals' => list<[keys, cluster]>,
     *  'retracted' => list<string>, 'members' => members].
     *
     * @param array<string, array<string, array{0: string, 1: string}>> $oldMembers
     * @param list<array<string, array{0: string, 1: string}>> $clusters
     * @param array<string, array{0: string, 1: string}> $shared
     * @return array{minted: list<string>, split: list<array{0: string, 1: list<array{0: string, 1: array<string, array{0: string, 1: string}>}>}>, proposals: list<array{0: list<string>, 1: array<string, array{0: string, 1: string}>}>, retracted: list<string>, members: array<string, array<string, array{0: string, 1: string}>>}
     */
    private static function reconcile(array $oldMembers, int $next, string $prefix, array $clusters, array $shared): array
    {
        $original = $oldMembers;
        $conflicts = self::clusterConflicts($clusters, $shared);
        $heldCodes = Sets::of(array_map(static fn (array $conflict): array => $conflict[0], $conflicts));
        $nonBridging = Sets::union($shared, $heldCodes);

        // Pass 1 — place each cluster: mint (no overlap), extend (one key), or propose (many keys).
        // assigns/minted/proposals are PREPENDED in Elixir; we append then reverse to match order.
        $assigns = [];     // list of [cluster, key]
        $members = $oldMembers;
        $minted = [];      // list of key (reversed at end)
        $proposals = [];   // list of [sortedKeys, cluster] (reversed at end)

        foreach ($clusters as $cluster) {
            $keys = self::overlappingKeys($original, $cluster, $nonBridging);

            if ($keys === []) {
                $key = $prefix.'_'.$next;
                $assigns[] = [$cluster, $key];
                $members[$key] = $cluster;
                $minted[] = $key;
                ++$next;
            } elseif (count($keys) === 1) {
                $key = $keys[0];
                $assigns[] = [$cluster, $key];
                $members[$key] = $cluster;
            } else {
                // GATED: never auto-merge established keys — propose for steward review.
                $proposals[] = [$keys, $cluster];
            }
        }

        $minted = array_reverse($minted);
        $proposals = array_reverse($proposals);

        // Pass 2 — split detection: any key assigned MORE THAN ONE cluster keeps one and carves the
        // others into freshly minted keys. Group assigns by key, preserving first-appearance order
        // (Enum.group_by semantics) over the ORIGINAL (un-reversed) assigns order.
        $grouped = self::groupAssignsByKey($assigns);

        $split = []; // list of [key, into] where into = list of [newKey, cluster]
        foreach ($grouped as [$key, $multiple]) {
            if (count($multiple) === 1) {
                continue;
            }

            $prior = $original[$key] ?? [];

            // keep_cluster = max_by {has_spine?, intersection size with prior}. Elixir Enum.max_by
            // keeps the FIRST max on ties, scanning in list order.
            $keepIdx = 0;
            $keepScore = self::keepScore($multiple[0][0], $prior);
            for ($i = 1, $n = count($multiple); $i < $n; ++$i) {
                $score = self::keepScore($multiple[$i][0], $prior);
                if (self::scoreGreater($score, $keepScore)) {
                    $keepScore = $score;
                    $keepIdx = $i;
                }
            }
            $keepCluster = $multiple[$keepIdx][0];

            // Mint a new key for every cluster except the kept one, in list order.
            $into = [];
            foreach ($multiple as $idx => [$cluster, $_assignedKey]) {
                if ($idx === $keepIdx) {
                    continue;
                }
                $nk = $prefix.'_'.$next;
                $members[$nk] = $cluster;
                $into[] = [$nk, $cluster];
                ++$next;
            }

            $members[$key] = $keepCluster;
            $split[] = [$key, $into];
        }

        $heldProposals = [];
        $seenHeldKeys = [];
        foreach ($conflicts as [$_code, $carriers]) {
            $keys = [];
            foreach ($carriers as $carrier) {
                foreach ($assigns as [$cluster, $key]) {
                    if (self::sameSet($cluster, $carrier)) {
                        $keys[] = $key;
                        break;
                    }
                }
            }
            $keys = array_values(array_unique($keys));
            sort($keys, SORT_STRING);
            if (count($keys) < 2) {
                continue;
            }

            $keySignature = implode("\x1f", $keys);
            if (isset($seenHeldKeys[$keySignature])) {
                continue;
            }
            $seenHeldKeys[$keySignature] = true;

            $candidate = [];
            foreach ($carriers as $carrier) {
                $candidate = Sets::union($candidate, $carrier);
            }
            $heldProposals[] = [$keys, $candidate];
        }
        $proposals = array_merge($proposals, $heldProposals);

        $assignedKeys = [];
        foreach ($assigns as [$_cluster, $key]) {
            $assignedKeys[$key] = true;
        }
        foreach ($proposals as [$keys, $_cluster]) {
            foreach ($keys as $key) {
                $assignedKeys[$key] = true;
            }
        }
        $retracted = [];
        foreach ($original as $key => $_codes) {
            if (!isset($assignedKeys[$key])) {
                $retracted[] = $key;
            }
        }
        sort($retracted, SORT_STRING);
        foreach ($retracted as $key) {
            unset($members[$key]);
        }

        return [
            'minted' => $minted,
            'split' => $split,
            'proposals' => $proposals,
            'conflicts' => $conflicts,
            'retracted' => $retracted,
            'members' => $members,
        ];
    }

    /**
     * Build the identity events from a reconcile outcome, in Elixir's emission order:
     * mints, then splits, then proposals, then keeps_changed.
     *
     * @param array<string, array<string, array{0: string, 1: string}>> $oldMembers
     * @param array{minted: list<string>, split: list<array{0: string, 1: list<array{0: string, 1: array<string, array{0: string, 1: string}>}>}>, proposals: list<array{0: list<string>, 1: array<string, array{0: string, 1: string}>}>, retracted: list<string>, members: array<string, array<string, array{0: string, 1: string}>>} $outcome
     * @return list<array<string,mixed>>
     */
    private static function buildEvents(array $oldMembers, array $outcome, mixed $at): array
    {
        $events = [];

        foreach ($outcome['minted'] as $key) {
            $events[] = Events::identityMinted($key, $outcome['members'][$key], $at);
        }

        foreach ($outcome['split'] as [$key, $into]) {
            $intoWithCodes = [];
            foreach ($into as [$nk, $_cluster]) {
                $intoWithCodes[] = [$nk, $outcome['members'][$nk]];
            }
            $events[] = Events::identitySplit($key, $outcome['members'][$key], $intoWithCodes, $at);
        }

        foreach ($outcome['proposals'] as [$keys, $cluster]) {
            $events[] = Events::conflictFlagged(['merge', $keys], $cluster, $at);
        }

        foreach ($outcome['conflicts'] as [$code, $carriers]) {
            $candidates = array_map(static fn (array $carrier): array => array_values($carrier), $carriers);
            $events[] = Events::conflictFlagged(['identity_conflict', $code], $candidates, $at);
        }

        foreach ($outcome['retracted'] as $key) {
            $events[] = Events::identityRetracted($key, $oldMembers[$key] ?? [], $at);
        }

        foreach (self::keepsChanged($oldMembers, $outcome, $at) as $e) {
            $events[] = $e;
        }

        return $events;
    }

    /**
     * IdentityMembersChanged for every PRE-EXISTING key whose code-set changed and was not part of
     * a split (split keys are reported via IdentitySplit, not a member change).
     *
     * @param array<string, array<string, array{0: string, 1: string}>> $oldMembers
     * @param array{split: list<array{0: string, 1: list<array{0: string, 1: array<string, array{0: string, 1: string}>}>}>, members: array<string, array<string, array{0: string, 1: string}>>} $outcome
     * @return list<array<string,mixed>>
     */
    private static function keepsChanged(array $oldMembers, array $outcome, mixed $at): array
    {
        $skip = [];
        foreach ($outcome['split'] as [$key, $into]) {
            $skip[$key] = true;
            foreach ($into as [$nk, $_codes]) {
                $skip[$nk] = true;
            }
        }

        $events = [];
        foreach ($oldMembers as $key => $old) {
            if (isset($skip[$key])) {
                continue;
            }
            if (!array_key_exists($key, $outcome['members'])) {
                continue;
            }
            if (!self::sameSet($outcome['members'][$key], $old)) {
                $events[] = Events::identityMembersChanged($key, $outcome['members'][$key], $at);
            }
        }

        return $events;
    }

    /**
     * The keys whose (non-shared) codes overlap this cluster's (non-shared) codes, sorted.
     *
     * @param array<string, array<string, array{0: string, 1: string}>> $members
     * @param array<string, array{0: string, 1: string}> $cluster
     * @param array<string, array{0: string, 1: string}> $shared
     * @return list<string>
     */
    private static function overlappingKeys(array $members, array $cluster, array $shared): array
    {
        $bare = Sets::difference($cluster, $shared);

        $keys = [];
        foreach ($members as $k => $codes) {
            if (!Sets::disjoint(Sets::difference($codes, $shared), $bare)) {
                $keys[] = $k;
            }
        }
        sort($keys, SORT_STRING);

        return $keys;
    }

    /**
     * A non-shared code present in multiple guarded clusters is the bridge that was held.
     *
     * @param list<array<string, array{0: string, 1: string}>> $clusters
     * @param array<string, array{0: string, 1: string}> $shared
     * @return list<array{0: array{0: string, 1: string}, 1: list<array<string, array{0: string, 1: string}>>}>
     */
    private static function clusterConflicts(array $clusters, array $shared): array
    {
        $byCode = [];
        foreach ($clusters as $index => $cluster) {
            foreach ($cluster as $key => $code) {
                if (!isset($shared[$key])) {
                    $byCode[$key]['code'] = $code;
                    $byCode[$key]['carriers'][$index] = $cluster;
                }
            }
        }
        ksort($byCode, SORT_STRING);

        $out = [];
        foreach ($byCode as $entry) {
            $carriers = array_values($entry['carriers']);
            if (count($carriers) > 1) {
                $out[] = [$entry['code'], $carriers];
            }
        }

        return $out;
    }

    /**
     * Group [cluster, key] assigns by key into [key, list-of-assigns], preserving the order in
     * which each key first appears — exactly Elixir's `Enum.group_by` over the assigns list.
     *
     * @param list<array{0: array<string, array{0: string, 1: string}>, 1: string}> $assigns
     * @return list<array{0: string, 1: list<array{0: array<string, array{0: string, 1: string}>, 1: string}>>}
     */
    private static function groupAssignsByKey(array $assigns): array
    {
        $order = [];
        $groups = [];
        foreach ($assigns as $assign) {
            $key = $assign[1];
            if (!isset($groups[$key])) {
                $groups[$key] = [];
                $order[] = $key;
            }
            $groups[$key][] = $assign;
        }

        $out = [];
        foreach ($order as $key) {
            $out[] = [$key, $groups[$key]];
        }

        return $out;
    }

    /**
     * The keep-heuristic score: [hasGtinSpine, intersectionSizeWithPrior].
     *
     * @param array<string, array{0: string, 1: string}> $cluster
     * @param array<string, array{0: string, 1: string}> $prior
     * @return array{0: bool, 1: int}
     */
    private static function keepScore(array $cluster, array $prior): array
    {
        return [self::hasSpine($cluster), Sets::size(Sets::intersection($cluster, $prior))];
    }

    /**
     * @param array{0: bool, 1: int} $a
     * @param array{0: bool, 1: int} $b
     */
    private static function scoreGreater(array $a, array $b): bool
    {
        // Elixir compares tuples: {false,_} < {true,_}; then by the int. Booleans compare false<true.
        return [$a[0] ? 1 : 0, $a[1]] > [$b[0] ? 1 : 0, $b[1]];
    }

    /** @param array<string, array{0: string, 1: string}> $cluster */
    private static function hasSpine(array $cluster): bool
    {
        foreach ($cluster as $code) {
            if ($code[0] === 'gtin') {
                return true;
            }
        }

        return false;
    }

    /** The trailing integer of a key ("SK_7" => 7, "SUB_3" => 3). */
    private static function keyNum(string $key): int
    {
        $parts = explode('_', $key);

        return (int) end($parts);
    }

    /**
     * Set equality by keys (the values are equal whenever the keys are, since keys derive from them).
     *
     * @param array<string, array{0: string, 1: string}> $a
     * @param array<string, array{0: string, 1: string}> $b
     */
    private static function sameSet(array $a, array $b): bool
    {
        if (count($a) !== count($b)) {
            return false;
        }
        foreach ($a as $k => $_) {
            if (!isset($b[$k])) {
                return false;
            }
        }

        return true;
    }
}
