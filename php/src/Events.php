<?php

declare(strict_types=1);

namespace Ingot;

/**
 * Domain / identity events — ported from the `Events.*` structs in lib/golden_record_core.ex.
 *
 * Each Elixir struct becomes a tagged assoc array: `['type' => Events::TYPE_*, ...fields]`. The
 * named static constructors give the same readability and key-discipline as the structs, and the
 * TYPE_* constants let folds (`IdentityLedger::evolve`, the change feed) dispatch on `['type']`.
 *
 * A ClaimAsserted carries `source`, `kind`, `data`, `valid_from`, `recorded_at`, `order`; its
 * `kind` is one of {identity, grouping, attribute, media, edge, member_of}. On the 422156 fold
 * path only IdentityMinted / IdentityMembersChanged / IdentitySplit / ConflictFlagged and
 * ClaimAsserted are actually emitted, but the full set is provided for fidelity.
 */
final class Events
{
    public const TYPE_CLAIM_ASSERTED = 'claim_asserted';
    public const TYPE_IDENTITY_MINTED = 'identity_minted';
    public const TYPE_IDENTITY_MEMBERS_CHANGED = 'identity_members_changed';
    public const TYPE_IDENTITIES_MERGED = 'identities_merged';
    public const TYPE_IDENTITY_SPLIT = 'identity_split';
    public const TYPE_LEGACY_ID_ASSIGNED = 'legacy_id_assigned';
    public const TYPE_CONFLICT_FLAGGED = 'conflict_flagged';
    public const TYPE_MERGE_PROPOSED = 'merge_proposed';
    public const TYPE_IDENTITY_RETRACTED = 'identity_retracted';
    public const TYPE_CONFLICT_RESOLVED = 'conflict_resolved';

    /**
     * @param array<string,mixed> $data the kind-specific payload (codes are sets/pairs)
     * @return array<string,mixed>
     */
    public static function claimAsserted(
        ?string $source,
        string $kind,
        array $data,
        mixed $validFrom,
        mixed $recordedAt,
        ?int $order = null
    ): array {
        return [
            'type' => self::TYPE_CLAIM_ASSERTED,
            'source' => $source,
            'kind' => $kind,
            'data' => $data,
            'valid_from' => $validFrom,
            'recorded_at' => $recordedAt,
            'order' => $order,
        ];
    }

    /**
     * @param array<string, array{0: string, 1: string}> $codes a code-set
     * @return array<string,mixed>
     */
    public static function identityMinted(string $key, array $codes, mixed $recordedAt, ?int $order = null): array
    {
        return [
            'type' => self::TYPE_IDENTITY_MINTED,
            'key' => $key,
            'codes' => $codes,
            'recorded_at' => $recordedAt,
            'order' => $order,
        ];
    }

    /**
     * @param array<string, array{0: string, 1: string}> $codes a code-set
     * @return array<string,mixed>
     */
    public static function identityMembersChanged(string $key, array $codes, mixed $recordedAt, ?int $order = null): array
    {
        return [
            'type' => self::TYPE_IDENTITY_MEMBERS_CHANGED,
            'key' => $key,
            'codes' => $codes,
            'recorded_at' => $recordedAt,
            'order' => $order,
        ];
    }

    /**
     * @param list<string> $from
     * @return array<string,mixed>
     */
    public static function identitiesMerged(array $from, string $into, mixed $recordedAt, ?int $order = null): array
    {
        return [
            'type' => self::TYPE_IDENTITIES_MERGED,
            'from' => $from,
            'into' => $into,
            'recorded_at' => $recordedAt,
            'order' => $order,
        ];
    }

    /**
     * @param array<string, array{0: string, 1: string}> $keptCodes a code-set
     * @param list<array{0: string, 1: array<string, array{0: string, 1: string}>}> $into [newKey, codeSet] pairs
     * @return array<string,mixed>
     */
    public static function identitySplit(string $key, array $keptCodes, array $into, mixed $recordedAt, ?int $order = null): array
    {
        return [
            'type' => self::TYPE_IDENTITY_SPLIT,
            'key' => $key,
            'kept_codes' => $keptCodes,
            'into' => $into,
            'recorded_at' => $recordedAt,
            'order' => $order,
        ];
    }

    /**
     * The bookend of identityMinted: a key whose every contributing listing was retracted.
     * `codes` carries the codes the key HELD before retraction (the notification payload).
     *
     * @param array<string, array{0: string, 1: string}> $codes a code-set
     * @return array<string,mixed>
     */
    public static function identityRetracted(string $key, array $codes, mixed $recordedAt, ?int $order = null): array
    {
        return [
            'type' => self::TYPE_IDENTITY_RETRACTED,
            'key' => $key,
            'codes' => $codes,
            'recorded_at' => $recordedAt,
            'order' => $order,
        ];
    }

    /**
     * `subject` is a tagged tuple as a list, e.g. ['merge', [keys]] or ['collision', key].
     *
     * @param array<int,mixed> $subject
     * @param mixed $candidates
     * @return array<string,mixed>
     */
    public static function conflictFlagged(array $subject, mixed $candidates, mixed $recordedAt, ?int $order = null): array
    {
        return [
            'type' => self::TYPE_CONFLICT_FLAGGED,
            'subject' => $subject,
            'candidates' => $candidates,
            'recorded_at' => $recordedAt,
            'order' => $order,
        ];
    }

    /** @param list<string> $keys */
    public static function mergeProposed(
        array $keys,
        string $by,
        mixed $recordedAt,
        ?string $reason = null,
        ?int $order = null,
    ): array {
        return [
            'type' => self::TYPE_MERGE_PROPOSED,
            'keys' => $keys,
            'by' => $by,
            'reason' => $reason,
            'recorded_at' => $recordedAt,
            'order' => $order,
        ];
    }

    public static function conflictResolved(
        array $subject,
        mixed $decision,
        string $by,
        mixed $recordedAt,
        ?string $reason = null,
        ?int $order = null,
    ): array {
        return [
            'type' => self::TYPE_CONFLICT_RESOLVED,
            'subject' => $subject,
            'decision' => $decision,
            'by' => $by,
            'reason' => $reason,
            'recorded_at' => $recordedAt,
            'order' => $order,
        ];
    }
}
