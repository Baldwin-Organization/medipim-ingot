<?php

declare(strict_types=1);

namespace Ingot;

/**
 * One golden record: a product label and its projected {@see Variant}s — the page shape
 * {@see Catalog::project} groups variants into and {@see GoldenRecords::project} enriches.
 */
final readonly class GoldenRecord
{
    /** @param list<Variant> $variants */
    public function __construct(
        public mixed $product,
        public array $variants,
    ) {
    }
}
