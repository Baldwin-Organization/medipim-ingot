<?php

declare(strict_types=1);

namespace Ingot;

/**
 * One in-memory domain event — a claim or an identity event — as the engine fold speaks it.
 *
 * The wire/persisted form stays a tagged assoc array (see {@see Events::fromArray} /
 * {@see DomainEvent::toArray}); inside the fold every event is one of these objects, so call
 * sites read as language (`$claim->kind`, `$event->recordedAt`) instead of key indexing.
 * `toArray` reproduces the exact key order the tagged arrays always had, so persisted payloads,
 * fingerprints and parity dumps stay byte-identical.
 */
interface DomainEvent
{
    /** The wire tag ({@see Events}::TYPE_*). */
    public function type(): string;

    /** The durable log offset (null until stamped). */
    public function order(): ?int;

    /** A copy stamped with its log offset — events are immutable, folds re-stamp by replacing. */
    public function withOrder(int $order): static;

    /** The tagged assoc array (the wire/persisted shape), keys in the canonical order. */
    public function toArray(): array;
}
