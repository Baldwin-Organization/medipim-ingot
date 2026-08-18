<?php

declare(strict_types=1);

namespace Ingot;

/**
 * A key's identity fate — active, merged (with its forwarding target), or split (with the keys it
 * fragmented into). `toArray` reproduces the wire map shape the HTTP view and dumps always used.
 */
final readonly class IdentityStatus
{
    /** @param list<string>|null $splitInto */
    private function __construct(
        public string $status,
        public ?string $supersededBy = null,
        public ?array $splitInto = null,
    ) {
    }

    public static function active(): self
    {
        return new self('active');
    }

    public static function merged(string $supersededBy): self
    {
        return new self('merged', $supersededBy);
    }

    /** @param list<string> $splitInto */
    public static function split(array $splitInto): self
    {
        return new self('split', null, $splitInto);
    }

    /** @return array<string,mixed> */
    public function toArray(): array
    {
        return match ($this->status) {
            'merged' => ['status' => 'merged', 'superseded_by' => $this->supersededBy],
            'split' => ['status' => 'split', 'split_into' => $this->splitInto],
            default => ['status' => $this->status],
        };
    }
}
