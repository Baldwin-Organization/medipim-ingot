<?php

declare(strict_types=1);

namespace Ingot;

/**
 * Temporal predicates over domain events — ported from `Bitemporal` (lib/bitemporal.ex).
 *
 * Temporals reach here as unix-second ints (the backfill's contract-C stamps) or ISO-8601 strings
 * (dates or datetimes); everything normalizes through {@see effectiveDate} / {@see toUnix} before
 * comparing. Effective intervals are half-open: `valid_from <= date < valid_to`.
 */
final class Bitemporal
{
    /** Transaction time: was the event recorded by `$knownAt`? */
    public static function known(DomainEvent $e, mixed $knownAt): bool
    {
        return self::toUnix($e->recordedAt) <= self::toUnix($knownAt);
    }

    /** Valid time: does the event's `[valid_from, valid_to)` window cover `$effectiveAt` (a 'Y-m-d' date)? */
    public static function effective(DomainEvent $e, string $effectiveAt): bool
    {
        $from = self::effectiveDate(self::validFrom($e) ?? $e->recordedAt);
        $to = self::validTo($e);

        return strcmp($from, $effectiveAt) <= 0
            && ($to === null || strcmp($effectiveAt, self::effectiveDate($to)) < 0);
    }

    /** Normalize any temporal to a 'Y-m-d' UTC date string. */
    public static function effectiveDate(mixed $value): string
    {
        if (is_int($value)) {
            return gmdate('Y-m-d', $value);
        }
        if (is_string($value) && preg_match('/^\d{4}-\d{2}-\d{2}/', $value) === 1) {
            return substr($value, 0, 10);
        }
        if ($value instanceof \DateTimeInterface) {
            return $value->format('Y-m-d');
        }

        throw new \InvalidArgumentException('not a temporal: '.get_debug_type($value));
    }

    /** Normalize any temporal to unix seconds (a date counts as its UTC midnight). */
    public static function toUnix(mixed $value): int
    {
        if (is_int($value)) {
            return $value;
        }
        if (is_string($value)) {
            return (new \DateTimeImmutable($value, new \DateTimeZone('UTC')))->getTimestamp();
        }
        if ($value instanceof \DateTimeInterface) {
            return $value->getTimestamp();
        }

        throw new \InvalidArgumentException('not a temporal: '.get_debug_type($value));
    }

    // Only claims carry a validity window on the PHP side (Elixir identity events have the fields
    // too, but the ingest leaves them nil) — every other event is effective from its recording.
    private static function validFrom(DomainEvent $e): mixed
    {
        return $e instanceof Claim ? $e->validFrom : null;
    }

    private static function validTo(DomainEvent $e): mixed
    {
        return $e instanceof Claim ? $e->validTo : null;
    }
}
