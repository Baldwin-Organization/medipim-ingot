<?php

declare(strict_types=1);

namespace Ingot;

/**
 * The engine refusing to guess: `subject` names what needs a steward, as a tagged tuple-list —
 * ['merge', [keys]], ['identity_conflict', code], ['identity_swap', key], ['source_withdrew', key].
 */
final readonly class ConflictFlagged implements DomainEvent
{
    /** @param array<int,mixed> $subject */
    public function __construct(
        public array $subject,
        public mixed $candidates,
        public mixed $recordedAt,
        public ?int $order = null,
    ) {
    }

    public function type(): string
    {
        return Events::TYPE_CONFLICT_FLAGGED;
    }

    public function order(): ?int
    {
        return $this->order;
    }

    public function withOrder(int $order): static
    {
        return new self($this->subject, $this->candidates, $this->recordedAt, $order);
    }

    public function toArray(): array
    {
        return [
            'type' => Events::TYPE_CONFLICT_FLAGGED,
            'subject' => $this->subject,
            'candidates' => $this->candidates,
            'recorded_at' => $this->recordedAt,
            'order' => $this->order,
        ];
    }
}
