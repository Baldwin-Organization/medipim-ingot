<?php

declare(strict_types=1);

namespace Ingot;

/** A new surrogate key born for a cluster no existing key overlapped. */
final readonly class IdentityMinted implements DomainEvent
{
    /** @param array<string, array{0: string, 1: string}> $codes a code-set */
    public function __construct(
        public string $key,
        public array $codes,
        public mixed $recordedAt,
        public ?int $order = null,
    ) {
    }

    public function type(): string
    {
        return Events::TYPE_IDENTITY_MINTED;
    }

    public function order(): ?int
    {
        return $this->order;
    }

    public function withOrder(int $order): static
    {
        return new self($this->key, $this->codes, $this->recordedAt, $order);
    }

    public function toArray(): array
    {
        return [
            'type' => Events::TYPE_IDENTITY_MINTED,
            'key' => $this->key,
            'codes' => $this->codes,
            'recorded_at' => $this->recordedAt,
            'order' => $this->order,
        ];
    }
}
