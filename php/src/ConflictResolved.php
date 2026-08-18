<?php

declare(strict_types=1);

namespace Ingot;

/** A steward's decision on a flagged conflict — the paper trail of every human call. */
final readonly class ConflictResolved implements DomainEvent
{
    /** @param array<int,mixed> $subject */
    public function __construct(
        public array $subject,
        public mixed $decision,
        public string $by,
        public mixed $recordedAt,
        public ?string $reason = null,
        public ?int $order = null,
    ) {
    }

    public function type(): string
    {
        return Events::TYPE_CONFLICT_RESOLVED;
    }

    public function order(): ?int
    {
        return $this->order;
    }

    public function withOrder(int $order): static
    {
        return new self($this->subject, $this->decision, $this->by, $this->recordedAt, $this->reason, $order);
    }

    public function toArray(): array
    {
        return [
            'type' => Events::TYPE_CONFLICT_RESOLVED,
            'subject' => $this->subject,
            'decision' => $this->decision,
            'by' => $this->by,
            'reason' => $this->reason,
            'recorded_at' => $this->recordedAt,
            'order' => $this->order,
        ];
    }
}
