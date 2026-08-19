<?php

declare(strict_types=1);

namespace Ingot;

/**
 * Raw `<entity>_deltas` rows -> a contract-C {@see EnvelopeLoader} envelope. The production twin of
 * the one-off Elixir oracle `test/ingest/fixtures/gen.exs`: it applies medipim's decode rules
 * (documented in docs/HISTORY_ENVELOPE.md) so the same envelope the oracle bootstrapped from a dump
 * is reproduced at runtime from the live `products_deltas` / `descriptions_deltas` / `media_deltas`
 * / `leaflets_deltas` rows — they all share ONE row shape, so one decoder serves every lane.
 *
 * Decode rules (validated against the real 422156 + 347025 data):
 *   - opcode 1=set 2=add 3=remove 4=delete; the string opcode "update_sources" is dropped (a
 *     survivorship recompute, not a data change — this engine owns resolution).
 *   - key grammar field[:locale][:organizationId]: a trailing all-digit segment is the source
 *     (organization id); a 2-letter alpha segment is the locale.
 *   - opcode 4 (delete) carries the source in the VALUE, not the key.
 *   - some values carry a redundant "{field}_" prefix (eanGtin13_/eanGtin14_/...) — stripped for ANY
 *     field that carries it.
 *   - meta fields (updatedAt/updatedBy/createdAt/createdBy/legacyId) are dropped; a delta that
 *     reduces to nothing but meta is a touch-only delta (dropped_meta_count++).
 *   - last_touched_at = max updatedAt over ALL deltas (incl. dropped ones) and every created_at.
 *   - identity classification is driven by {@see CodeRegistry::identityFields()} — adding a market is
 *     a registry change, not a decoder change.
 */
final class EnvelopeDecoder
{
    private const SCHEMA_VERSION = '1';

    /** opcode => op name. */
    private const OP = ['1' => 'set', '2' => 'add', '3' => 'remove', '4' => 'delete'];

    /** Collections that reference first-class lane entities (media + descriptions). */
    private const MEDIA = ['media', 'descriptions', 'leaflets'];

    /** Structural edge collections (membership in a grouping namespace). */
    private const EDGE = ['publicCategories', 'brands', 'labos', 'internationalBrands', 'medipimCategories', 'organizations'];

    /** Meta fields dropped entirely (updatedAt also bumps last_touched_at before being dropped). */
    private const META_DROP = ['updatedAt', 'updatedBy', 'createdAt', 'createdBy', 'legacyId'];

    /**
     * Decode a legacy entity's full delta history into a contract-C envelope (a plain assoc array,
     * shaped exactly like the committed `.json` fixtures and accepted by {@see EnvelopeLoader::fromMap}).
     *
     * @param list<array<string,mixed>> $deltas raw rows, each {events: [[op,key,value],...], created_at, created_by, tag}
     * @param array{identity_fields?: array<string,true>, identity_scheme?: IdentityScheme|string, identity_source?: string} $opts
     *        `identity_scheme` injects an entity-level identity ({@see IdentityScheme}, e.g. TextId/AssetId)
     *        so a non-product entity whose deltas carry no identity code still mints a lane record;
     *        `identity_source` is the asserting source for that injected identity (default: source_system).
     * @return array<string,mixed>
     */
    public static function decode(array $deltas, string $sourceSystem, int|string $legacyEntity, array $opts = []): array
    {
        $identity = $opts['identity_fields'] ?? CodeRegistry::identityFields();

        $events = [];
        $dropped = 0;
        $lastTouched = 0;

        foreach ($deltas as $delta) {
            [$kept, $lastTouched] = self::processDelta($delta, $lastTouched, $identity);
            if ($kept === []) {
                ++$dropped;
            } else {
                foreach ($kept as $e) {
                    $events[] = $e;
                }
            }
        }

        if (isset($opts['identity_scheme'])) {
            $identitySource = $opts['identity_source'] ?? $sourceSystem;
            $scheme = IdentityScheme::coerce($opts['identity_scheme'])->value;
            array_unshift($events, self::entityIdentity($scheme, $identitySource, $legacyEntity, $deltas));
        }

        return [
            'schema_version' => self::SCHEMA_VERSION,
            'source_system' => $sourceSystem,
            'legacy_entity' => $legacyEntity,
            'last_touched_at' => $lastTouched,
            'dropped_meta_count' => $dropped,
            'events' => $events,
        ];
    }

    /**
     * Decode one JSONL dump (one raw delta per line) — the `.raw.jsonl` fixture format.
     *
     * @param array{identity_fields?: array<string,true>, identity_scheme?: IdentityScheme|string} $opts
     * @return array<string,mixed>
     */
    public static function decodeJsonl(string $jsonl, string $sourceSystem, int|string $legacyEntity, array $opts = []): array
    {
        $deltas = [];
        foreach (explode("\n", $jsonl) as $line) {
            $line = trim($line);
            if ($line === '') {
                continue;
            }
            $deltas[] = json_decode($line, true, 512, JSON_THROW_ON_ERROR);
        }

        return self::decode($deltas, $sourceSystem, $legacyEntity, $opts);
    }

    /**
     * @param array<string,mixed> $delta
     * @param array<string,true> $identity
     * @return array{0: list<array<string,mixed>>, 1: int}
     */
    private static function processDelta(array $delta, int $lastTouched, array $identity): array
    {
        $recordedAt = $delta['created_at'] ?? null;
        $by = $delta['created_by'] ?? null;
        $tag = $delta['tag'] ?? null;

        $kept = [];
        foreach ($delta['events'] ?? [] as $triple) {
            $opcode = $triple[0] ?? null;
            $key = $triple[1] ?? null;
            $value = $triple[2] ?? null;
            $field = $key !== null ? explode(':', (string) $key)[0] : null;

            if ($opcode === 'update_sources') {
                continue;
            }
            if ($field === 'updatedAt') {
                if (is_int($value)) {
                    $lastTouched = max($lastTouched, $value);
                }
                continue;
            }
            if ($field !== null && in_array($field, self::META_DROP, true)) {
                continue;
            }

            $kept[] = self::decodeEvent($field, $key, (string) $opcode, $value, $recordedAt, $by, $tag, $identity);
        }

        if (is_int($recordedAt)) {
            $lastTouched = max($lastTouched, $recordedAt);
        }

        return [$kept, $lastTouched];
    }

    /**
     * @param array<string,true> $identity
     * @return array<string,mixed>
     */
    private static function decodeEvent(?string $field, ?string $key, string $opcode, mixed $value, mixed $recordedAt, mixed $by, mixed $tag, array $identity): array
    {
        $op = self::OP[$opcode] ?? $opcode;
        [$locale, $source] = self::parseKey($key);

        // opcode 4 (delete): the source lives in the value, and there is no payload value.
        if ($op === 'delete') {
            $source = self::stringOrNull($value) ?? $source;
            $value = null;
        }

        $event = ['recorded_at' => $recordedAt];
        if ($by !== null) {
            $event['by'] = $by;
        }
        if ($tag !== null) {
            $event['tag'] = $tag;
        }

        $kind = self::kindOf($field, $identity);
        $event['op'] = $op;
        $event['kind'] = $kind;
        if ($source !== null) {
            $event['source'] = $source;
        }

        foreach (self::kindPayload($kind, $field, $op, $locale, $value) as $k => $v) {
            $event[$k] = $v;
        }

        return $event;
    }

    /**
     * @return array<string,mixed>
     */
    private static function kindPayload(string $kind, ?string $field, string $op, ?string $locale, mixed $value): array
    {
        switch ($kind) {
            case 'identity':
                $out = ['scheme' => $field];
                if ($op === 'delete') {
                    return $out;
                }
                $out['code'] = $value === null ? null : self::stripFieldPrefix($field, Stringify::value($value));

                return $out;
            case 'attribute':
                $out = ['field' => $field];
                if ($locale !== null) {
                    $out['locale'] = $locale;
                }
                if ($op !== 'delete') {
                    $out['value'] = $value;
                }

                return $out;
            case 'media':
                $out = ['collection' => $field];
                if ($op !== 'delete') {
                    $out['asset'] = $value;
                }

                return $out;
            default: // edge
                $out = ['collection' => $field];
                if ($op !== 'delete') {
                    $out['value'] = $value;
                }

                return $out;
        }
    }

    /** @param array<string,true> $identity */
    private static function kindOf(?string $field, array $identity): string
    {
        if ($field === null) {
            return 'attribute';
        }
        if (isset($identity[$field])) {
            return 'identity';
        }
        if (in_array($field, self::MEDIA, true)) {
            return 'media';
        }
        if (in_array($field, self::EDGE, true)) {
            return 'edge';
        }

        return 'attribute';
    }

    /**
     * Segments after the field: an all-digit one is the source, an all-alpha one is the locale.
     *
     * @return array{0: ?string, 1: ?string} [locale, source]
     */
    private static function parseKey(?string $key): array
    {
        if ($key === null) {
            return [null, null];
        }

        $segs = explode(':', $key);
        array_shift($segs); // drop the field

        $locale = null;
        $source = null;
        foreach ($segs as $seg) {
            if ($seg !== '' && ctype_digit($seg)) {
                $source = $seg;
            } elseif ($seg !== '' && ctype_alpha($seg)) {
                $locale = $seg;
            }
        }

        return [$locale, $source];
    }

    /** Strip a leading "{field}_" for ANY field whose value carries it — generic, not GTIN-only. */
    private static function stripFieldPrefix(?string $field, string $code): string
    {
        if ($field === null) {
            return $code;
        }
        $prefix = $field.'_';

        return str_starts_with($code, $prefix) ? substr($code, strlen($prefix)) : $code;
    }

    private static function stringOrNull(mixed $v): ?string
    {
        return $v === null ? null : Stringify::value($v);
    }

    /**
     * A synthetic entity-level identity for a non-product lane (descriptions/media): the entity's own
     * id under a lane scheme, so {@see ClaimMapping} mints a lane key and anchors its attributes.
     *
     * @param list<array<string,mixed>> $deltas
     * @return array<string,mixed>
     */
    private static function entityIdentity(string $scheme, string $source, int|string $legacyEntity, array $deltas): array
    {
        $at = null;
        foreach ($deltas as $delta) {
            if (isset($delta['created_at'])) {
                $at = $delta['created_at'];
                break;
            }
        }

        return [
            'recorded_at' => $at,
            'op' => 'set',
            'kind' => 'identity',
            'source' => $source,
            'scheme' => $scheme,
            'code' => (string) $legacyEntity,
        ];
    }
}
