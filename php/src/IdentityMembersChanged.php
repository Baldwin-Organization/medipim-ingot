<?php

declare(strict_types=1);

namespace Ingot;

/** An existing key's code-set changed (codes gained or lost) without a split. */
final readonly class IdentityMembersChanged implements DomainEvent
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
        return Events::TYPE_IDENTITY_MEMBERS_CHANGED;
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
            'type' => Events::TYPE_IDENTITY_MEMBERS_CHANGED,
            'key' => $this->key,
            'codes' => $this->codes,
            'recorded_at' => $this->recordedAt,
            'order' => $this->order,
        ];
    }
}
