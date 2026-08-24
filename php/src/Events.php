<?php

declare(strict_types=1);

namespace Ingot;

/**
 * Domain / identity events — ported from the `Events.*` structs in lib/golden_record_core.ex.
 *
 * Each Elixir struct is a typed {@see DomainEvent} class ({@see Claim}, {@see IdentityMinted}, …);
 * the named static constructors here keep the one construction grammar the folds always used, and
 * the TYPE_* constants remain the wire tags. `fromArray`/`toArrays` are the boundary codec: the
 * store and the dumps speak tagged assoc arrays, the in-memory fold speaks objects.
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

    /** @param array<string,mixed> $data the kind-specific payload (codes are sets/pairs) */
    public static function claimAsserted(
        ?string $source,
        string $kind,
        array $data,
        mixed $validFrom,
        mixed $recordedAt,
        ?int $order = null,
        mixed $validTo = null,
        mixed $by = null
    ): Claim {
        return new Claim($source, $kind, $data, $validFrom, $recordedAt, $order, $validTo, $by);
    }

    /** @param array<string, array{0: string, 1: string}> $codes a code-set */
    public static function identityMinted(string $key, array $codes, mixed $recordedAt, ?int $order = null): IdentityMinted
    {
        return new IdentityMinted($key, $codes, $recordedAt, $order);
    }

    /** @param array<string, array{0: string, 1: string}> $codes a code-set */
    public static function identityMembersChanged(string $key, array $codes, mixed $recordedAt, ?int $order = null): IdentityMembersChanged
    {
        return new IdentityMembersChanged($key, $codes, $recordedAt, $order);
    }

    /** @param list<string> $from */
    public static function identitiesMerged(array $from, string $into, mixed $recordedAt, ?int $order = null): IdentitiesMerged
    {
        return new IdentitiesMerged($from, $into, $recordedAt, $order);
    }

    /**
     * @param array<string, array{0: string, 1: string}> $keptCodes a code-set
     * @param list<array{0: string, 1: array<string, array{0: string, 1: string}>}> $into [newKey, codeSet] pairs
     */
    public static function identitySplit(string $key, array $keptCodes, array $into, mixed $recordedAt, ?int $order = null): IdentitySplit
    {
        return new IdentitySplit($key, $keptCodes, $into, $recordedAt, $order);
    }

    /** @param array<string, array{0: string, 1: string}> $codes the codes the key HELD before retraction */
    public static function identityRetracted(string $key, array $codes, mixed $recordedAt, ?int $order = null): IdentityRetracted
    {
        return new IdentityRetracted($key, $codes, $recordedAt, $order);
    }

    /** @param array<int,mixed> $subject a tagged tuple as a list, e.g. ['merge', [keys]] */
    public static function conflictFlagged(array $subject, mixed $candidates, mixed $recordedAt, ?int $order = null): ConflictFlagged
    {
        return new ConflictFlagged($subject, $candidates, $recordedAt, $order);
    }

    /** @param list<string> $keys */
    public static function mergeProposed(
        array $keys,
        string $by,
        mixed $recordedAt,
        ?string $reason = null,
        ?int $order = null,
    ): MergeProposed {
        return new MergeProposed($keys, $by, $recordedAt, $reason, $order);
    }

    /** @param array<int,mixed> $subject */
    public static function conflictResolved(
        array $subject,
        mixed $decision,
        string $by,
        mixed $recordedAt,
        ?string $reason = null,
        ?int $order = null,
    ): ConflictResolved {
        return new ConflictResolved($subject, $decision, $by, $recordedAt, $reason, $order);
    }

    // ── the array boundary (store rows, dumps) ──────────────────────────────────

    /**
     * Revive one persisted/tagged event array as its typed object.
     *
     * @param array<string,mixed> $e
     */
    public static function fromArray(array $e): DomainEvent
    {
        return match ($e['type'] ?? null) {
            self::TYPE_CLAIM_ASSERTED => new Claim(
                $e['source'], $e['kind'], $e['data'], $e['valid_from'], $e['recorded_at'], $e['order'] ?? null,
                $e['valid_to'] ?? null, $e['by'] ?? null
            ),
            self::TYPE_IDENTITY_MINTED => new IdentityMinted($e['key'], $e['codes'], $e['recorded_at'], $e['order'] ?? null),
            self::TYPE_IDENTITY_MEMBERS_CHANGED => new IdentityMembersChanged($e['key'], $e['codes'], $e['recorded_at'], $e['order'] ?? null),
            self::TYPE_IDENTITIES_MERGED => new IdentitiesMerged($e['from'], $e['into'], $e['recorded_at'], $e['order'] ?? null),
            self::TYPE_IDENTITY_SPLIT => new IdentitySplit($e['key'], $e['kept_codes'], $e['into'], $e['recorded_at'], $e['order'] ?? null),
            self::TYPE_IDENTITY_RETRACTED => new IdentityRetracted($e['key'], $e['codes'], $e['recorded_at'], $e['order'] ?? null),
            self::TYPE_CONFLICT_FLAGGED => new ConflictFlagged($e['subject'], $e['candidates'], $e['recorded_at'], $e['order'] ?? null),
            self::TYPE_MERGE_PROPOSED => new MergeProposed($e['keys'], $e['by'], $e['recorded_at'], $e['reason'] ?? null, $e['order'] ?? null),
            self::TYPE_CONFLICT_RESOLVED => new ConflictResolved(
                $e['subject'], $e['decision'], $e['by'], $e['recorded_at'], $e['reason'] ?? null, $e['order'] ?? null
            ),
            default => throw new \InvalidArgumentException('unknown event type: '.var_export($e['type'] ?? null, true)),
        };
    }

    /**
     * @param list<array<string,mixed>> $events
     * @return list<DomainEvent>
     */
    public static function fromArrays(array $events): array
    {
        return array_map(self::fromArray(...), $events);
    }

    /**
     * @param list<DomainEvent> $events
     * @return list<array<string,mixed>>
     */
    public static function toArrays(array $events): array
    {
        return array_map(static fn (DomainEvent $e): array => $e->toArray(), $events);
    }
}
