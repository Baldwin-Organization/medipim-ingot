<?php

declare(strict_types=1);

namespace Ingot;

/**
 * One survivorship outcome — the answer for one dimension (an attribute field, the product label,
 * a public id): the winning value, who won, whether it resolved, and the ranked candidate list.
 * A tie among distinct top-ranked values resolves nothing: `value`/`winner` are null and
 * `status` is `needs_review` — the engine never invents a winner.
 */
final readonly class Decision
{
    /** @param list<array{0: ?string, 1: mixed}> $candidates ranked [source, value] pairs */
    public function __construct(
        public mixed $value,
        public ?string $winner,
        public string $status,
        public array $candidates,
    ) {
    }

    public function resolved(): bool
    {
        return $this->status !== 'needs_review';
    }

    public function needsReview(): bool
    {
        return $this->status === 'needs_review';
    }

    /** @return array{value: mixed, winner: ?string, status: string, candidates: list<array{0: ?string, 1: mixed}>} */
    public function toArray(): array
    {
        return [
            'value' => $this->value,
            'winner' => $this->winner,
            'status' => $this->status,
            'candidates' => $this->candidates,
        ];
    }
}
