<?php

declare(strict_types=1);

namespace Ingot\Storage;

/**
 * The storage PORT the consuming app implements (medipim provides a DBAL adapter; the package ships
 * {@see InMemoryClaimStore} as the reference + test double). Dependency-free: every method speaks
 * plain arrays/scalars, so the package never reaches for Doctrine.
 *
 * The model is lane-agnostic and per-key (it scales without a global snapshot blob):
 *   - `events`    — the append-only log, the system of record (one row per event, `seq` = offset).
 *   - per-key snapshot — each surrogate key's current code-set + current claim view ({@see saveKey}).
 *   - `members`   — the code -> key resolution index (the ledger, as queryable rows).
 *   - `redirects` — old key -> new key after a merge (clients holding a stale key resolve forward).
 *   - `lane_seq`  — the per-lane mint counter, so surrogate keys are globally unique within a lane.
 *   - backfill idempotency — a per-(entity, fingerprint) marker.
 *
 * All writes by {@see ClaimIngest} run inside {@see transactionally} (the single-writer lock); the
 * key is lane-qualified (`SK_`/`SUB_`/`DSC_`/`MED_`), so `lane` is always derivable from it.
 */
interface ClaimStore
{
    /** Run `$fn()` under the global writer lock, in one transaction; return its value (or roll back on throw). */
    public function transactionally(callable $fn): mixed;

    /** The highest event offset assigned so far (0 when the log is empty). */
    public function maxSeq(): int;

    /**
     * Append already-offset-stamped events to the log (each event's `order` is its durable `seq`).
     *
     * @param list<array<string,mixed>> $events
     */
    public function appendEvents(array $events): void;

    /**
     * The full decoded log in `seq` order — for rebuilds and as-of projections (not the hot path).
     *
     * @return list<array<string,mixed>>
     */
    public function log(): array;

    /**
     * Resolve code keys ({@see \Ingot\Codes::key} form, "scheme\x1fvalue") to the surrogate
     * key that owns each — only present ones.
     *
     * @param list<string> $codeKeys
     * @return array<string,string> codeKey => surrogateKey
     */
    public function resolveKeys(array $codeKeys): array;

    /** Resolve a single code key to its current owning surrogate key (following redirects), or null. */
    public function resolveKey(string $codeKey): ?string;

    /**
     * Load the per-key snapshot for each surrogate key (missing keys are simply absent).
     *
     * @param list<string> $surrogateKeys
     * @return array<string, array{lane: string, codes: array<string, array{0:string,1:string}>, claims: list<array<string,mixed>>, last_seq: int}>
     */
    public function loadKeys(array $surrogateKeys): array;

    /**
     * Upsert a key's snapshot (code-set + current claim view) AND its `members` rows in one shot.
     *
     * @param array<string, array{0:string,1:string}> $codes the key's code-set
     * @param list<array<string,mixed>> $claims the key's current claim view (one per slot)
     */
    public function saveKey(string $surrogateKey, string $lane, array $codes, array $claims, int $lastSeq): void;

    /** Drop a key absorbed by a merge — removes its snapshot and `members` rows. */
    public function removeKey(string $surrogateKey): void;

    /** Record that `$oldKey` was merged into `$newKey`. */
    public function addRedirect(string $oldKey, string $newKey, mixed $at): void;

    /** The next mint counter for a lane (1 when the lane has never minted). */
    public function laneNext(string $lane): int;

    /** Persist the next mint counter for a lane. */
    public function setLaneNext(string $lane, int $next): void;

    /** Has this (entity, fingerprint) backfill envelope already been ingested? */
    public function backfillSeen(string $legacyEntity, string $fingerprint): bool;

    /** Mark a backfill envelope ingested (idempotency). */
    public function markBackfillSeen(string $legacyEntity, string $fingerprint): void;

    /**
     * Add to the durable shared-codes map (restricted/non-bridging identity codes) — add-only, so
     * a stored code is never forgotten. Lets identity reconcile be re-run from the store alone,
     * without replaying every envelope ever ingested (gh-119).
     *
     * @param array<string, array{0:string,1:string}> $codes a code-set ({@see \Ingot\Sets})
     */
    public function addShared(array $codes): void;

    /**
     * The full durable shared-codes map — the union of every code ever passed to {@see addShared}.
     *
     * @return array<string, array{0:string,1:string}>
     */
    public function allShared(): array;

    /**
     * Record where one legacy entity currently resolves to — the durable legacy -> surrogate-key
     * cross-reference (gh-120). An upsert: re-saving the same (source_system, legacy_entity)
     * overwrites its prior row.
     */
    public function saveLegacyXref(string $sourceSystem, string $legacyEntity, string $surrogateKey, string $placement = 'stable'): void;

    /** Resolve one (source_system, legacy_entity) to its current surrogate key (following redirects), or null if never recorded. */
    public function resolveLegacy(string $sourceSystem, string $legacyEntity): ?string;

    /**
     * Bulk-resolve (source_system, legacy_entity) pairs — only present ones.
     *
     * @param list<array{0:string,1:string}> $pairs
     * @return array<string,string> "sourceSystem\x1flegacyEntity" => surrogateKey
     */
    public function resolveLegacies(array $pairs): array;

    /**
     * Follow merge redirects from a (possibly stale) surrogate key to the current live key —
     * the key itself when it was never absorbed (gh-118). Presence is not checked: a key with
     * neither snapshot nor redirect resolves to itself.
     */
    public function resolveSurrogate(string $surrogateKey): string;
}
