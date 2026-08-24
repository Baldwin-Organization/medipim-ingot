<?php

declare(strict_types=1);

namespace Ingot;

/**
 * One interval of a listing's code history: from `from` (inclusive) until `to` (exclusive, null =
 * still applicable), the listing carried exactly `codes`. A period with no codes is a delisting —
 * kept, because an identity claim with no codes retracts the listing.
 *
 * Mirrors the period maps of `ClaimMapping.listing_periods/1` in lib/ingest/claim_mapping.ex.
 */
final readonly class Period
{
    public function __construct(
        public int $from,
        public ?int $to,
        public CodeSet $codes,
        /** who recorded the event that opened (or last rewrote) this period (gh-132) */
        public mixed $by = null,
    ) {
    }

    /** Half-open: from inclusive, to exclusive. */
    public function covers(int $at): bool
    {
        return $at >= $this->from && ($this->to === null || $at < $this->to);
    }

    /** No codes — the listing delisted for this interval. */
    public function isDelisting(): bool
    {
        return $this->codes->isEmpty();
    }

    public function opensAt(int $at): bool
    {
        return $this->from === $at;
    }

    public function closesAt(int $at): bool
    {
        return $this->to === $at;
    }

    /** Readers work at day granularity, so a same-UTC-day period could never apply to any date. */
    public function openedSameUtcDayAs(int $at): bool
    {
        return intdiv($this->from, 86400) === intdiv($at, 86400);
    }

    public function closedAt(int $at): self
    {
        return new self($this->from, $at, $this->codes, $this->by);
    }

    public function withCodes(CodeSet $codes, mixed $by = null): self
    {
        return new self($this->from, $this->to, $codes, $by);
    }
}
