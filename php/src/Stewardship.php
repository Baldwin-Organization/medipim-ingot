<?php

declare(strict_types=1);

namespace Ingot;

/**
 * Stewardship detection — ported from `Stewardship` in lib/golden_record_core.ex.
 *
 * Pure projections over the identity state that surface items for the steward queue.
 * `detectWithdrawals` flags keys that lost a source (the source retracted its listing)
 * but still survive under other sources — the steward needs visibility.
 */
final class Stewardship
{
    /**
     * Reviewed merge override. Besides the merge events, persist standing `same` evidence for
     * every conflicting national-id pair so a later replay does not immediately split the keys.
     *
     * @param array<string, array<string, array{0: string, 1: string}>> $members
     * @param list<string> $keys
     * @return list<DomainEvent>
     */
    public static function approveMerge(
        array $members,
        array $keys,
        string $by,
        mixed $at,
        ?string $reason = null,
    ): array {
        sort($keys, SORT_STRING);
        $survivor = $keys[0];
        $union = [];
        foreach ($keys as $key) {
            $union = Sets::union($union, $members[$key] ?? []);
        }

        $evidence = [];
        $seen = [];
        foreach ($keys as $leftIndex => $leftKey) {
            foreach (array_slice($keys, $leftIndex + 1) as $rightKey) {
                foreach ($members[$leftKey] ?? [] as $left) {
                    foreach ($members[$rightKey] ?? [] as $right) {
                        if (
                            $left[0] !== $right[0]
                            || $left === $right
                            || !CodeRegistry::nationalGrade($left[0])
                        ) {
                            continue;
                        }

                        if (Sets::compareCodes($left, $right) > 0) {
                            [$left, $right] = [$right, $left];
                        }
                        $pairKey = Codes::key($left)."\x1e".Codes::key($right);
                        if (isset($seen[$pairKey])) {
                            continue;
                        }
                        $seen[$pairKey] = true;
                        $evidence[] = Substrate::claim('steward', 'identity_evidence', [
                            'relation' => 'same',
                            'left' => $left,
                            'right' => $right,
                            'by' => $by,
                            'reason' => $reason,
                        ], $at, $at);
                    }
                }
            }
        }

        return array_merge($evidence, [
            Events::identitiesMerged($keys, $survivor, $at),
            Events::identityMembersChanged($survivor, $union, $at),
            Events::conflictResolved(['merge', $keys], 'approved', $by, $at, $reason),
        ]);
    }

    /**
     * Flag SOURCE WITHDRAWALS: a source retracted its listing (codes: []) but the key
     * survives under other sources.
     *
     * @param list<Claim> $oldLive current identity claims BEFORE the retraction
     * @param list<Claim> $newLive current identity claims AFTER the retraction
     * @param array<string, array<string, array{0: string, 1: string}>> $members post-reconcile ledger members
     * @return list<ConflictFlagged> flags with subject ['source_withdrew', key]
     */
    public static function detectWithdrawals(array $oldLive, array $newLive, array $members, mixed $at): array
    {
        $oldSources = self::sourcesPerKey($oldLive, $members);
        $newSources = self::sourcesPerKey($newLive, $members);

        $flags = [];
        foreach ($members as $key => $_codes) {
            $old = $oldSources[$key] ?? [];
            $new = $newSources[$key] ?? [];

            $lost = array_diff($old, $new);
            if ($lost === []) {
                continue;
            }

            $candidates = [];
            foreach ($lost as $source) {
                $candidates[] = ['source' => $source];
            }

            $flags[] = Events::conflictFlagged(['source_withdrew', $key], $candidates, $at);
        }

        return $flags;
    }

    /**
     * For each key, compute which sources contribute non-empty identity claims with codes
     * that belong to that key's code-set.
     *
     * @param list<Claim> $liveClaims
     * @param array<string, array<string, array{0: string, 1: string}>> $members
     * @return array<string, list<string>> key => list of source names
     */
    private static function sourcesPerKey(array $liveClaims, array $members): array
    {
        $result = [];
        foreach ($liveClaims as $claim) {
            if ($claim->kind !== 'identity') {
                continue;
            }
            if (empty($claim->data['codes'])) {
                continue;
            }
            foreach ($members as $key => $codes) {
                foreach ($claim->data['codes'] as $code) {
                    if (Sets::member($codes, $code)) {
                        $result[$key][] = $claim->source;
                        break;
                    }
                }
            }
        }

        foreach ($result as $key => $sources) {
            $result[$key] = array_values(array_unique($sources));
        }

        return $result;
    }
}
