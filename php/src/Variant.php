<?php

declare(strict_types=1);

namespace Ingot;

/**
 * One projected catalog variant — a surrogate key with everything the read side derives for it.
 * `attributes` are sorted [field, {@see Decision}] pairs; `product` is the product-label decision;
 * `cnk` (canonical + aliases, or null) is grafted on by {@see GoldenRecords::project} via
 * {@see withCnk}. The nested media/categories/substances/descriptions entries stay plain arrays —
 * they are page furniture the canonical document renders directly.
 */
final readonly class Variant
{
    /**
     * @param list<array{0: string, 1: string}> $codes sorted [scheme, value] pairs
     * @param list<array{0: string, 1: Decision}> $attributes
     * @param list<array<string,mixed>> $media
     * @param list<array{0: string, 1: string}> $categories
     * @param list<array<string,mixed>> $substances
     * @param list<array<string,mixed>> $descriptions
     * @param array<string,mixed>|null $cnk
     */
    public function __construct(
        public string $key,
        public array $codes,
        public array $attributes,
        public Decision $product,
        public array $media,
        public array $categories,
        public array $substances,
        public array $descriptions,
        public ?array $cnk = null,
    ) {
    }

    /** @param array<string,mixed>|null $cnk */
    public function withCnk(?array $cnk): self
    {
        return new self(
            $this->key,
            $this->codes,
            $this->attributes,
            $this->product,
            $this->media,
            $this->categories,
            $this->substances,
            $this->descriptions,
            $cnk,
        );
    }

    /** The decision for one attribute field, or null when the variant carries no such field. */
    public function attribute(string $field): ?Decision
    {
        foreach ($this->attributes as [$f, $decision]) {
            if ($f === $field) {
                return $decision;
            }
        }

        return null;
    }
}
