<?php

declare(strict_types=1);

namespace Ingot;

/**
 * HistoryEnvelope loader — ported from `HistoryEnvelope` (lib/ingest/envelope_loader.ex).
 *
 * Parses + validates one decoded legacy entity's history (contract C). Does NO resolution: events
 * stay flat and time-ordered, each given a stable 0..n-1 `order` index. The result is an
 * {@see Envelope} of {@see DecodedEvent}s with kind-specific {@see DecodedPayload}s.
 *
 * Loaders return either ['ok', Envelope] or ['error', reason] — mirroring the Elixir result tuples.
 */
final class EnvelopeLoader
{
    private const SUPPORTED_SCHEMA_VERSIONS = ['1'];
    private const OPS = ['set' => 'set', 'add' => 'add', 'remove' => 'remove', 'delete' => 'delete'];
    private const KINDS = ['identity' => 'identity', 'attribute' => 'attribute', 'edge' => 'edge', 'media' => 'media'];

    /**
     * Load + validate one envelope file. ['ok', envelope] | ['error', reason].
     *
     * @return array{0: string, 1: mixed}
     */
    public static function load(string $path): array
    {
        if (!is_file($path)) {
            return ['error', ['file', $path, 'enoent']];
        }
        $raw = file_get_contents($path);
        if ($raw === false) {
            return ['error', ['file', $path, 'eaccess']];
        }

        return self::fromJson($raw);
    }

    /** Like load/1 but throws on error, returning the envelope directly. */
    public static function loadBang(string $path): Envelope
    {
        $result = self::load($path);
        if ($result[0] !== 'ok') {
            throw new \RuntimeException('invalid envelope '.$path.': '.json_encode($result[1]));
        }

        return $result[1];
    }

    /**
     * Parse a JSON string into a validated envelope.
     *
     * @return array{0: string, 1: mixed}
     */
    public static function fromJson(string $json): array
    {
        try {
            $map = json_decode($json, true, 512, JSON_THROW_ON_ERROR);
        } catch (\JsonException $e) {
            return ['error', ['invalid_json', $e->getMessage()]];
        }

        return self::fromMap($map);
    }

    /**
     * Validate a decoded (string-keyed) map and build the envelope.
     *
     * @return array{0: string, 1: mixed}
     */
    public static function fromMap(mixed $m): array
    {
        if (!is_array($m) || array_is_list($m)) {
            return ['error', 'not_an_object'];
        }

        $version = self::validateSchemaVersion($m['schema_version'] ?? null);
        if ($version[0] !== 'ok') {
            return $version;
        }

        $events = self::buildEvents($m['events'] ?? null);
        if ($events[0] !== 'ok') {
            return $events;
        }

        return ['ok', new Envelope(
            $version[1],
            $m['source_system'] ?? null,
            $m['legacy_entity'] ?? null,
            $m['last_touched_at'] ?? null,
            $m['dropped_meta_count'] ?? null,
            $events[1],
        )];
    }

    /**
     * Count events by kind.
     *
     * @return array<string,int>
     */
    public static function kindCounts(Envelope $env): array
    {
        $counts = [];
        foreach ($env->events as $e) {
            $counts[$e->kind] = ($counts[$e->kind] ?? 0) + 1;
        }

        return $counts;
    }

    /** @return array{0: string, 1: mixed} */
    private static function validateSchemaVersion(mixed $v): array
    {
        return in_array($v, self::SUPPORTED_SCHEMA_VERSIONS, true)
            ? ['ok', $v]
            : ['error', ['unsupported_schema_version', $v]];
    }

    /** @return array{0: string, 1: mixed} */
    private static function buildEvents(mixed $list): array
    {
        if ($list === null) {
            return ['error', 'missing_events'];
        }
        if (!is_array($list) || !array_is_list($list)) {
            return ['error', 'events_not_a_list'];
        }

        $events = [];
        foreach ($list as $i => $raw) {
            $ev = self::buildEvent($raw, $i);
            if ($ev[0] !== 'ok') {
                return ['error', ['event', $i, $ev[1]]];
            }
            $events[] = $ev[1];
        }

        return ['ok', $events];
    }

    /** @return array{0: string, 1: mixed} */
    private static function buildEvent(mixed $m, int $order): array
    {
        if (!is_array($m) || array_is_list($m)) {
            return ['error', 'event_not_an_object'];
        }

        $op = self::atomFor(self::OPS, $m['op'] ?? null, 'unknown_op');
        if ($op[0] !== 'ok') {
            return $op;
        }
        $kind = self::atomFor(self::KINDS, $m['kind'] ?? null, 'unknown_kind');
        if ($kind[0] !== 'ok') {
            return $kind;
        }
        $data = self::payload($kind[1], $m);
        if ($data[0] !== 'ok') {
            return $data;
        }

        return ['ok', new DecodedEvent(
            $m['recorded_at'] ?? null,
            $m['valid_from'] ?? ($m['recorded_at'] ?? null),
            $m['by'] ?? null,
            $m['tag'] ?? null,
            $m['source'] ?? null,
            $op[1],
            $kind[1],
            $data[1],
            $order,
        )];
    }

    /**
     * @param array<string,string> $table
     * @return array{0: string, 1: mixed}
     */
    private static function atomFor(array $table, mixed $key, string $err): array
    {
        if (is_string($key) && isset($table[$key])) {
            return ['ok', $table[$key]];
        }

        return ['error', [$err, $key]];
    }

    /**
     * @param array<string,mixed> $m
     * @return array{0: string, 1: mixed}
     */
    private static function payload(string $kind, array $m): array
    {
        return match ($kind) {
            'identity' => self::requireKeys($m, ['scheme'], static fn (): DecodedPayload => new IdentityDelta($m['scheme'], $m['code'] ?? null)),
            'attribute' => self::requireKeys($m, ['field'], static fn (): DecodedPayload => new AttributeDelta($m['field'], $m['locale'] ?? null, $m['value'] ?? null)),
            'edge' => self::requireKeys($m, ['collection'], static fn (): DecodedPayload => new EdgeDelta($m['collection'], $m['value'] ?? null)),
            'media' => self::requireKeys($m, ['collection', 'asset'], static fn (): DecodedPayload => new MediaDelta($m['collection'], $m['asset'])),
            default => ['error', ['unknown_kind', $kind]],
        };
    }

    /**
     * @param array<string,mixed> $m
     * @param list<string> $keys
     * @param callable(): DecodedPayload $build
     * @return array{0: string, 1: mixed}
     */
    private static function requireKeys(array $m, array $keys, callable $build): array
    {
        $missing = [];
        foreach ($keys as $k) {
            if (!array_key_exists($k, $m)) {
                $missing[] = $k;
            }
        }

        return $missing === [] ? ['ok', $build()] : ['error', ['missing_keys', $missing]];
    }
}
