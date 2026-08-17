<?php

declare(strict_types=1);

namespace Ingot;

/**
 * One product code — a {scheme, value} pair as a value object, so call sites read as language
 * (`$code->isRestricted()`, `$code->canonical()`) instead of positional array indexing.
 *
 * The engine-wide mechanics stay owned by `Codes` (canonicalization, restriction ranges, set
 * keys) and `CanonicalClaims` (the wire spelling); this object only gives them a readable
 * surface. `pair()` / `fromPair()` bridge to the `[scheme, value]` representation the engine
 * fold still speaks.
 */
final readonly class Code implements \Stringable
{
    public function __construct(
        public string $scheme,
        public string $value,
    ) {
    }

    /** @param array{0: string, 1: string} $pair */
    public static function fromPair(array $pair): self
    {
        return new self($pair[0], $pair[1]);
    }

    /** @return array{0: string, 1: string} */
    public function pair(): array
    {
        return [$this->scheme, $this->value];
    }

    /** The canonical form (GTIN family → zero-padded GTIN-14, etc.). */
    public function canonical(): self
    {
        return self::fromPair(Codes::canonicalize($this->pair()));
    }

    public function is(string $scheme): bool
    {
        return $this->scheme === $scheme;
    }

    /** An in-store / restricted-range GTIN — carried, never allowed to bridge two products. */
    public function isRestricted(): bool
    {
        return Codes::restricted($this->pair());
    }

    /** The set key ("scheme␟value") — the identity `CodeSet` deduplicates on. */
    public function key(): string
    {
        return Codes::key($this->pair());
    }

    /** The wire spelling ("gtin:03282770146004"). */
    public function __toString(): string
    {
        return CanonicalClaims::codeString($this->pair());
    }
}
