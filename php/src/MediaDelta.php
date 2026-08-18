<?php

declare(strict_types=1);

namespace Ingot;

/** A media-reference delta: an asset id added to / removed from a media-ish collection. */
final readonly class MediaDelta implements DecodedPayload
{
    public function __construct(
        public mixed $collection,
        public mixed $asset,
    ) {
    }

    public function toArray(): array
    {
        return ['collection' => $this->collection, 'asset' => $this->asset];
    }
}
