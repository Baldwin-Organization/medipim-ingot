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
    /** Key encoding for a null source — Elixir keys listings on {entity, nil} (gr-c37). */
    private const NO_SOURCE = "\x00";

    public function __construct(
        public mixed $entity,
        public ?string $source,
    ) {
    }

    /** The wire ref an identity claim carries ("422156:1035"). */
    public function ref(): string
    {
        return $this->entity.':'.$this->source;
    }

    public function isFor(mixed $entity): bool
    {
        // Type-preserving, like Elixir's `e == entity`: int 422156 and string "422156" are
        // DIFFERENT entities — key() tags them apart, so matching must too (gr-c37).
        return $this->entity === $entity;
    }

    public function key(): string
    {
        return self::entityTag($this->entity)."\x1f".($this->source ?? self::NO_SOURCE);
    }

    /** The tagged entity scalar — the same encoding key() uses for its entity half. */
    public static function entityTag(mixed $entity): string
    {
        return (is_int($entity) ? 'i:' : 's:').$entity;
    }

    public static function fromKey(string $key): self
    {
        [$entityPart, $source] = explode("\x1f", $key, 2) + [1 => ''];
        $entity = str_starts_with($entityPart, 'i:') ? (int) substr($entityPart, 2) : substr($entityPart, 2);

        return new self($entity, $source === self::NO_SOURCE ? null : $source);
    }
}
