<?php

declare(strict_types=1);

namespace Ingot;

/** A structural edge delta: membership in a grouping collection (brands, categories, …). */
final readonly class EdgeDelta implements DecodedPayload
{
    public function __construct(
        public mixed $collection,
        public mixed $value,
    ) {
    }

    public function toArray(): array
    {
        return ['collection' => $this->collection, 'value' => $this->value];
    }
}
