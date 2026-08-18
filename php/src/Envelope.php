<?php

declare(strict_types=1);

namespace Ingot;

/**
 * One validated contract-C HistoryEnvelope — a legacy entity's full delta history as
 * {@see DecodedEvent}s. Built only by {@see EnvelopeLoader}; `toArray` reproduces the exact
 * validated-envelope map, so {@see \Ingot\Storage\ClaimIngest}'s backfill fingerprints stay
 * byte-identical.
 */
final readonly class Envelope
{
    /** @param list<DecodedEvent> $events */
    public function __construct(
        public string $schemaVersion,
        public mixed $sourceSystem,
        public mixed $legacyEntity,
        public mixed $lastTouchedAt,
        public mixed $droppedMetaCount,
        public array $events,
    ) {
    }

    /** @return array<string,mixed> */
    public function toArray(): array
    {
        return [
            'schema_version' => $this->schemaVersion,
            'source_system' => $this->sourceSystem,
            'legacy_entity' => $this->legacyEntity,
            'last_touched_at' => $this->lastTouchedAt,
            'dropped_meta_count' => $this->droppedMetaCount,
            'events' => array_map(static fn (DecodedEvent $e): array => $e->toArray(), $this->events),
        ];
    }
}
