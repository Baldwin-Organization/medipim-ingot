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
     * @return list<DomainEvent>
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

    /** Fold one identity event into the ledger. */
    public static function evolve(LedgerState $s, DomainEvent $event): LedgerState
    {
        if ($event instanceof IdentityMinted) {
            $members = $s->members;
            $members[$event->key] = $event->codes;

            return $s->with($members, max($s->next, self::keyNum($event->key) + 1));
        }

        if ($event instanceof IdentityMembersChanged) {
            $members = $s->members;
            $members[$event->key] = $event->codes;

            return $s->with($members);
        }

        if ($event instanceof IdentitiesMerged) {
            $members = $s->members;
            foreach ($event->from as $k) {
                if ($k !== $event->into) {
                    unset($members[$k]);
                }
            }

            return $s->with($members);
        }

        if ($event instanceof IdentitySplit) {
            $members = $s->members;
            $members[$event->key] = $event->keptCodes;
            $next = $s->next;
            foreach ($event->into as [$nk, $codes]) {
                $members[$nk] = $codes;
                $next = max($next, self::keyNum($nk) + 1);
            }

            return $s->with($members, $next);
        }

        if ($event instanceof IdentityRetracted) {
            $members = $s->members;
            unset($members[$event->key]);

            return $s->with($members);
        }

        // ConflictFlagged / MergeProposed / ConflictResolved / Claim
        return $s;
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

            // Elixir sorts the candidates by code signature and then takes Enum.max_by, which
            // keeps the FIRST maximum — so equal-ranked clusters resolve to the lowest signature
            // whatever order they arrived in. Selection is sorted; minting below is NOT, because
            // Elixir's `into` reduce walks the original order.
            $ordered = $multiple;
            usort(
                $ordered,
                static fn (array $a, array $b): int => strcmp(self::codeSignature($a[0]), self::codeSignature($b[0]))
            );

            $keepCluster = $ordered[0][0];
            $keepScore = self::keepScore($keepCluster, $prior);
            for ($i = 1, $n = count($ordered); $i < $n; ++$i) {
                $score = self::keepScore($ordered[$i][0], $prior);
                if (self::scoreGreater($score, $keepScore)) {
                    $keepScore = $score;
                    $keepCluster = $ordered[$i][0];
                }
            }

            $keepIdx = null;
            foreach ($multiple as $idx => [$cluster, $_k]) {
                if ($keepIdx === null && self::sameSet($cluster, $keepCluster)) {
                    $keepIdx = $idx;
                }
            }

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
            'swaps' => self::nationalSwaps($original, $members),
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
     * @return list<DomainEvent>
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
            // Elixir sorts each carrier (Enum.map(carriers, &Enum.sort/1)); a union-built set
            // is in insertion order otherwise (gr-51z).
            $candidates = array_map(static function (array $carrier): array {
                $codes = array_values($carrier);
                usort($codes, Sets::compareCodes(...));

                return $codes;
            }, $carriers);
            $events[] = Events::conflictFlagged(['identity_conflict', $code], $candidates, $at);
        }

        foreach ($outcome['swaps'] ?? [] as [$key, $lost, $now]) {
            $events[] = Events::conflictFlagged(['identity_swap', $key], [$lost, $now], $at);
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
     * @return list<IdentityMembersChanged>
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
     * Which cluster KEEPS the key on a split — mirrors IdentityLedger.keeper_rank/2.
     *
     * The old rule was "whichever side holds a GTIN". A barcode is explicitly reassignable
     * (NHSBSA publishes a GTIN Transfer Tracking Log of codes moving between packs), so that
     * let a transferred barcode drag the surrogate key to a different product. National codes
     * are assigned once and never reissued, so they say which cluster CONTINUES the key.
     *
     * @param array<string, array{0: string, 1: string}> $cluster
     * @param array<string, array{0: string, 1: string}> $prior
     *
     * @return array{0: int, 1: int, 2: int, 3: int}
     */
    private static function keepScore(array $cluster, array $prior): array
    {
        $shared = Sets::intersection($cluster, $prior);

        return [
            self::gradeCount($shared, 'national'),
            self::gradeCount($shared, 'none'),
            Sets::size($shared),
            self::gradeCount($cluster, 'national'),
        ];
    }

    /**
     * @param array{0: int, 1: int, 2: int, 3: int} $a
     * @param array{0: int, 1: int, 2: int, 3: int} $b
     */
    private static function scoreGreater(array $a, array $b): bool
    {
        // Elixir compares tuples element by element; PHP compares equal-length lists the same way.
        return $a > $b;
    }

    /**
     * The cluster's codes as a sorted list — Elixir's `Enum.sort(cluster)` on a MapSet of
     * {scheme, value} tuples, used only as a total tie-break.
     *
     * A byte-comparable stand-in for Elixir's Enum.sort(cluster) compared as a list of tuples:
     * codes sort byte-wise and the joined string compares element-first (a strict prefix sorts
     * first, matching shorter-list-first) — array <=> got both wrong (numeric values, count
     * before content; gr-51z).
     *
     * @param array<string, array{0: string, 1: string}> $cluster
     */
    private static function codeSignature(array $cluster): string
    {
        $keys = array_keys($cluster);
        sort($keys, SORT_STRING);

        return implode("\x1e", $keys);
    }

    /** @param array<string, array{0: string, 1: string}> $codes */
    private static function gradeCount(array $codes, string $grade): int
    {
        $n = 0;
        foreach ($codes as $code) {
            if (CodeRegistry::bridgeGrade($code[0]) === $grade) {
                ++$n;
            }
        }

        return $n;
    }

    /**
     * An established key that LOSES a national code has changed what it denotes. Gaining one is
     * an alias and stays quiet; losing one is the signature of a barcode transfer.
     *
     * @param array<string, array<string, array{0: string, 1: string}>> $original
     * @param array<string, array<string, array{0: string, 1: string}>> $live
     *
     * @return list<array{0: string, 1: list<array{0: string, 1: string}>, 2: list<array{0: string, 1: string}>}>
     */
    private static function nationalSwaps(array $original, array $live): array
    {
        $swaps = [];
        foreach ($original as $key => $prior) {
            if (!isset($live[$key])) {
                continue;
            }
            $lost = Sets::difference(self::nationalOnly($prior), self::nationalOnly($live[$key]));
            if (Sets::size($lost) === 0) {
                continue;
            }
            // Byte-wise tuple order like Elixir's Enum.sort — PHP's default sort compares
            // numeric strings numerically ('1035' before '44' flips, gr-51z).
            $now = array_values($live[$key]);
            $lostCodes = array_values($lost);
            usort($lostCodes, Sets::compareCodes(...));
            usort($now, Sets::compareCodes(...));
            $swaps[] = [$key, $lostCodes, $now];
        }
        usort($swaps, static fn (array $a, array $b): int => $a[0] <=> $b[0]);

        return $swaps;
    }

    /**
     * @param array<string, array{0: string, 1: string}> $codes
     *
     * @return array<string, array{0: string, 1: string}>
     */
    private static function nationalOnly(array $codes): array
    {
        $out = [];
        foreach ($codes as $slot => $code) {
            if (CodeRegistry::nationalGrade($code[0])) {
                $out[$slot] = $code;
            }
        }

        return $out;
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
