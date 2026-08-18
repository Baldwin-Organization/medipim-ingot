<?php

declare(strict_types=1);

namespace Ingot;

/**
 * Where one legacy entity landed in the re-derived world — {@see LegacyXref}'s per-entity answer.
 * `relation` keeps the tagged taxonomy: 'stable', 'split', ['merged', others] or
 * ['merged', others, 'suspect'] (a barcode-only bridge the over-merge guard distrusts).
 */
final readonly class Placement
{
    /** @param list<string> $all every key the entity's codes reach, primary first by spine rank */
    public function __construct(
        public string $primary,
        public array $all,
        public string|array $relation,
    ) {
    }

    /** @return array{primary: string, all: list<string>, relation: string|array} */
    public function toArray(): array
    {
        return [
            'primary' => $this->primary,
            'all' => $this->all,
            'relation' => $this->relation,
        ];
    }
}
