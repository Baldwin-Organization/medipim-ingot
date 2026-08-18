<?php

declare(strict_types=1);

namespace Ingot;

/** One key fragmented: it keeps `keptCodes`; each `into` pair is a freshly minted [key, code-set]. */
final readonly class IdentitySplit implements DomainEvent
{
    /**
     * @param array<string, array{0: string, 1: string}> $keptCodes a code-set
     * @param list<array{0: string, 1: array<string, array{0: string, 1: string}>}> $into [newKey, codeSet] pairs
     */
    public function __construct(
        public string $key,
        public array $keptCodes,
        public array $into,
        public mixed $recordedAt,
        public ?int $order = null,
    ) {
    }

    public function type(): string
    {
        return Events::TYPE_IDENTITY_SPLIT;
    }

    public function order(): ?int
    {
        return $this->order;
    }

    public function withOrder(int $order): static
    {
        return new self($this->key, $this->keptCodes, $this->into, $this->recordedAt, $order);
    }

    public function toArray(): array
    {
        return [
            'type' => Events::TYPE_IDENTITY_SPLIT,
            'key' => $this->key,
            'kept_codes' => $this->keptCodes,
            'into' => $this->into,
            'recorded_at' => $this->recordedAt,
            'order' => $this->order,
        ];
    }
}
