<?php

declare(strict_types=1);

namespace Ingot;

/** Steward-approved fusion: every key in `from` is absorbed into `into`. */
final readonly class IdentitiesMerged implements DomainEvent
{
    /** @param list<string> $from */
    public function __construct(
        public array $from,
        public string $into,
        public mixed $recordedAt,
        public ?int $order = null,
    ) {
    }

    public function type(): string
    {
        return Events::TYPE_IDENTITIES_MERGED;
    }

    public function order(): ?int
    {
        return $this->order;
    }

    public function withOrder(int $order): static
    {
        return new self($this->from, $this->into, $this->recordedAt, $order);
    }

    public function toArray(): array
    {
        return [
            'type' => Events::TYPE_IDENTITIES_MERGED,
            'from' => $this->from,
            'into' => $this->into,
            'recorded_at' => $this->recordedAt,
            'order' => $this->order,
        ];
    }
}
