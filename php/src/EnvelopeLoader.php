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
     * Scalar type rules per docs/HISTORY_ENVELOPE.md. The Elixir loader documents these types but
     * only checks key presence — safe there (any term can be a map key), not here: a non-string
     * `scheme` reaching ClaimMapping is an illegal array offset, so an out-of-contract envelope
     * must fail as ['error', reason] at this boundary instead of a TypeError mid-ingest.
     */
    private const ENVELOPE_TYPES = ['source_system' => 'string?', 'legacy_entity' => 'scalar?', 'last_touched_at' => 'scalar?', 'dropped_meta_count' => 'int?'];
    private const EVENT_TYPES = ['recorded_at' => 'int?', 'valid_from' => 'int?', 'by' => 'scalar?', 'tag' => 'string?', 'source' => 'string?'];
    private const PAYLOAD_TYPES = [
        'identity' => ['scheme' => 'string', 'code' => 'string?'],
        'attribute' => ['field' => 'string', 'locale' => 'string?'],
        'edge' => ['collection' => 'string'],
        'media' => ['collection' => 'string'],
    ];

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

        $types = self::checkTypes($m, self::ENVELOPE_TYPES);
        if ($types[0] !== 'ok') {
            return $types;
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
        $types = self::checkTypes($m, self::EVENT_TYPES);
        if ($types[0] !== 'ok') {
            return $types;
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
            'identity' => self::requireKeys($m, ['scheme'], $kind, static fn (): DecodedPayload => new IdentityDelta($m['scheme'], $m['code'] ?? null)),
            'attribute' => self::requireKeys($m, ['field'], $kind, static fn (): DecodedPayload => new AttributeDelta($m['field'], $m['locale'] ?? null, $m['value'] ?? null)),
            'edge' => self::requireKeys($m, ['collection'], $kind, static fn (): DecodedPayload => new EdgeDelta($m['collection'], $m['value'] ?? null)),
            'media' => self::requireKeys($m, ['collection', 'asset'], $kind, static fn (): DecodedPayload => new MediaDelta($m['collection'], $m['asset'])),
            default => ['error', ['unknown_kind', $kind]],
        };
    }

    /**
     * @param array<string,mixed> $m
     * @param list<string> $keys
     * @param callable(): DecodedPayload $build
     * @return array{0: string, 1: mixed}
     */
    private static function requireKeys(array $m, array $keys, string $kind, callable $build): array
    {
        $missing = [];
        foreach ($keys as $k) {
            if (!array_key_exists($k, $m)) {
                $missing[] = $k;
            }
        }
        if ($missing !== []) {
            return ['error', ['missing_keys', $missing]];
        }

        $types = self::checkTypes($m, self::PAYLOAD_TYPES[$kind]);

        return $types[0] === 'ok' ? ['ok', $build()] : $types;
    }

    /**
     * @param array<string,mixed> $m
     * @param array<string,string> $rules
     * @return array{0: string, 1: mixed}
     */
    private static function checkTypes(array $m, array $rules): array
    {
        foreach ($rules as $k => $rule) {
            $v = $m[$k] ?? null;
            $ok = match ($rule) {
                'string' => is_string($v),
                'string?' => $v === null || is_string($v),
                'int?' => $v === null || is_int($v),
                'scalar?' => $v === null || is_scalar($v),
            };
            if (!$ok) {
                return ['error', ['bad_type', $k, $v]];
            }
        }

        return ['ok', null];
    }
}
