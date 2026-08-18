<?php

declare(strict_types=1);

namespace Ingot;

/** A steward (or trusted source) proposing that `keys` denote one product. */
final readonly class MergeProposed implements DomainEvent
{
    /** @param list<string> $keys */
    public function __construct(
        public array $keys,
        public string $by,
        public mixed $recordedAt,
        public ?string $reason = null,
        public ?int $order = null,
    ) {
    }

    public function type(): string
    {
        return Events::TYPE_MERGE_PROPOSED;
    }

    public function order(): ?int
    {
        return $this->order;
    }

    public function withOrder(int $order): static
    {
        return new self($this->keys, $this->by, $this->recordedAt, $this->reason, $order);
    }

    public function toArray(): array
    {
        return [
            'type' => Events::TYPE_MERGE_PROPOSED,
            'keys' => $this->keys,
            'by' => $this->by,
            'reason' => $this->reason,
            'recorded_at' => $this->recordedAt,
            'order' => $this->order,
        ];
    }
}
