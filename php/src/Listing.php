<?php

declare(strict_types=1);

namespace Ingot;

/**
 * The identity of one listing: (legacy entity, source organization). One legacy entity typically
 * has several listings — one per source that describes it — and the per-listing fold is the unit
 * of the whole ingest.
 *
 * `key()` is the map-key encoding (entity scalar tagged so int 1 and string "1" cannot collide);
 * that encoding is this object's private business — call sites speak `$listing->entity` and
 * `$listing->source`.
 */
final readonly class Listing
{
    public function __construct(
        public mixed $entity,
        public string $source,
    ) {
    }

    /** The wire ref an identity claim carries ("422156:1035"). */
    public function ref(): string
    {
        return $this->entity.':'.$this->source;
    }

    public function isFor(mixed $entity): bool
    {
        return (string) $this->entity === (string) $entity;
    }

    public function key(): string
    {
        return (is_int($this->entity) ? 'i:' : 's:').$this->entity."\x1f".$this->source;
    }

    public static function fromKey(string $key): self
    {
        [$entityPart, $source] = explode("\x1f", $key, 2) + [1 => ''];
        $entity = str_starts_with($entityPart, 'i:') ? (int) substr($entityPart, 2) : substr($entityPart, 2);

        return new self($entity, $source);
    }
}
