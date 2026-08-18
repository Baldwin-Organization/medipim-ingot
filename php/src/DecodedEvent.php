<?php

declare(strict_types=1);

namespace Ingot;

/**
 * One validated contract-C history event — flat and time-ordered, with a stable 0..n-1 `order`
 * index and a kind-specific {@see DecodedPayload}. Built only by {@see EnvelopeLoader}; the decode
 * rules live there, this is just the shape.
 */
final readonly class DecodedEvent
{
    public function __construct(
        public mixed $recordedAt,
        public mixed $validFrom,
        public mixed $by,
        public mixed $tag,
        public mixed $source,
        public string $op,
        public string $kind,
        public DecodedPayload $data,
        public int $order,
    ) {
    }

    /** @return array<string,mixed> the validated event map, keys in the canonical order */
    public function toArray(): array
    {
        return [
            'recorded_at' => $this->recordedAt,
            'valid_from' => $this->validFrom,
            'by' => $this->by,
            'tag' => $this->tag,
            'source' => $this->source,
            'op' => $this->op,
            'kind' => $this->kind,
            'data' => $this->data->toArray(),
            'order' => $this->order,
        ];
    }
}
