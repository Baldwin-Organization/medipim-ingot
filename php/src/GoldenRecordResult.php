<?php

declare(strict_types=1);

namespace Ingot;

/**
 * The outcome of one fold (see {@see GoldenRecordEngine::ingest}). Holds the three projections off
 * the re-derived event log — golden records, legacy xref, migration diff — and exposes them both as
 * engine-native PHP arrays (for the consuming app to read) and as the canonical wire document the
 * parity oracle byte-matches.
 *
 * The read-side queries ({@see resolve}, {@see changesSince}, {@see identityStatus}) delegate to
 * {@see Api} over the event log, so a medipim-side adapter implementing
 * `ProductCodeLookupRepositoryInterface` can be a thin shim over this object.
 *
 * Immutable: every accessor returns the stored projection; nothing mutates after construction.
 */
final class GoldenRecordResult
{
    /**
     * @param array{records: list<GoldenRecord>, log: list<DomainEvent>} $gr
     * @param array{key_to_legacy: array<string, list<mixed>>, legacy_to_key: array<string, Placement>} $xref
     * @param array{findings: list<array<string,mixed>>, counts: array<string,int>, needs_review: list<array<string,mixed>>} $diff
     */
    public function __construct(
        private readonly array $gr,
        private readonly array $xref,
        private readonly array $diff,
    ) {
    }

    /**
     * Golden records: one per product, each with its variants (+ canonical CNK).
     *
     * @return list<GoldenRecord>
     */
    public function records(): array
    {
        return $this->gr['records'];
    }

    /**
     * The re-derived event log — the system of record the read-side queries fold over.
     *
     * @return list<DomainEvent>
     */
    public function log(): array
    {
        return $this->gr['log'];
    }

    /** Legacy-id cross-reference: legacy entity ⇄ surrogate key placement. */
    public function xref(): array
    {
        return $this->xref;
    }

    /**
     * Migration diff: {findings, counts, needs_review}. `needs_review` is the engine's explicit
     * "ambiguous" signal — the code/legacy placements a human (or the importer) must reconcile.
     *
     * @return array{findings: list<array<string,mixed>>, counts: array<string,int>, needs_review: list<array<string,mixed>>}
     */
    public function diff(): array
    {
        return $this->diff;
    }

    /** The canonical document (records + xref + diff), key-stable. */
    public function toDocument(): array
    {
        return Canonical422156::document($this->gr, $this->xref, $this->diff);
    }

    /** The canonical document encoded to the byte-matched wire JSON. */
    public function toJson(): string
    {
        return Canonical422156::encode($this->toDocument());
    }

    /**
     * Resolve any code (canonical or alias) to the surrogate key that currently owns it, or null.
     * Canonicalization (incl. GTIN cross-length) is applied — this is the identity-aware lookup.
     *
     * @param array{0: string, 1: string} $code
     */
    public function resolve(array $code): ?string
    {
        return Api::resolveKey($this->log(), $code);
    }

    /** Identity status of a key: active, merged (forwarding), or split. */
    public function identityStatus(string $key): IdentityStatus
    {
        return Api::identityStatus($this->log(), $key);
    }

    /**
     * Change feed: identity events with order > cursor, so consumers can repair local copies.
     *
     * @return list<DomainEvent>
     */
    public function changesSince(int $cursor): array
    {
        return Api::changesSince($this->log(), $cursor);
    }
}
