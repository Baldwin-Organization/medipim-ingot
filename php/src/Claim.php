<?php

declare(strict_types=1);

namespace Ingot;

/**
 * A ClaimAsserted — one source stating one fact ({@see Events} for the kind taxonomy). `data` is
 * the kind-specific payload and deliberately stays a plain array: its codes are engine
 * `[scheme, value]` pairs, the shape {@see Substrate::normalize} canonicalizes in place.
 */
final readonly class Claim implements DomainEvent
{
    /** @param array<string,mixed> $data */
    public function __construct(
        public ?string $source,
        public string $kind,
        public array $data,
        public mixed $validFrom,
        public mixed $recordedAt,
        public ?int $order = null,
        public mixed $validTo = null,
    ) {
    }

    public function type(): string
    {
        return Events::TYPE_CLAIM_ASSERTED;
    }

    public function order(): ?int
    {
        return $this->order;
    }

    public function withOrder(int $order): static
    {
        return new self($this->source, $this->kind, $this->data, $this->validFrom, $this->recordedAt, $order, $this->validTo);
    }

    public function toArray(): array
    {
        return [
            'type' => Events::TYPE_CLAIM_ASSERTED,
            'source' => $this->source,
            'kind' => $this->kind,
            'data' => $this->data,
            'valid_from' => $this->validFrom,
            'valid_to' => $this->validTo,
            'recorded_at' => $this->recordedAt,
            'order' => $this->order,
        ];
    }
}
