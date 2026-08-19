<?php

declare(strict_types=1);

namespace Ingot;

/**
 * The LIVE path's translator: a computed, current-truth snapshot -> a "now" contract-C envelope.
 *
 * Where {@see EnvelopeDecoder} replays a full delta HISTORY (the backfill path), this renders the
 * CURRENT state as one synthetic delta (every field a `set`, every collection member an `add`) at
 * `recorded_at = now`, then decodes it through the very same {@see EnvelopeDecoder} — so identity vs
 * attribute vs edge vs media classification is decided in exactly ONE place. The resulting envelope
 * feeds {@see \Ingot\Storage\ClaimIngest::live}, whose per-slot winnow makes an unchanged
 * write a no-op.
 *
 * The snapshot is given lane-agnostically as one entry per source (medipim organization):
 *   [
 *     ['source' => '1034',
 *      'fields' => ['cnk' => '3612173', 'status' => 'active', 'name' => ['nl' => '…', 'fr' => '…']],
 *      'collections' => ['media' => [158717], 'brands' => [9]]],
 *     ...
 *   ]
 * A `fields` value that is a locale map (assoc array) emits one event per locale; any other value is
 * a single scalar event. For a non-product lane (descriptions/media) whose snapshot carries no
 * identity code, pass `['identity_scheme' => IdentityScheme::TextId|AssetId]` (or the wire string)
 * so the entity mints a lane record.
 */
final class SnapshotTranslator
{
    /**
     * @param list<array{source?: ?string, fields?: array<string,mixed>, collections?: array<string, list<mixed>>}> $perSource
     * @param array{identity_fields?: array<string,true>, identity_scheme?: IdentityScheme|string, identity_source?: string, by?: mixed, tag?: ?string} $opts
     * @return array<string,mixed> a contract-C envelope map (feed to ClaimIngest::live)
     */
    public static function toEnvelope(array $perSource, string $sourceSystem, int|string $legacyEntity, ?int $recordedAt = null, array $opts = []): array
    {
        $recordedAt ??= time();

        $events = [];
        foreach ($perSource as $entry) {
            $source = $entry['source'] ?? null;

            foreach ($entry['fields'] ?? [] as $field => $value) {
                if (is_array($value) && !array_is_list($value)) {
                    foreach ($value as $locale => $localized) {
                        $events[] = ['1', self::key($field, (string) $locale, $source), $localized];
                    }
                } else {
                    $events[] = ['1', self::key($field, null, $source), $value];
                }
            }

            foreach ($entry['collections'] ?? [] as $collection => $members) {
                foreach ($members as $member) {
                    $events[] = ['2', self::key((string) $collection, null, $source), $member];
                }
            }
        }

        $delta = [
            'created_at' => $recordedAt,
            'created_by' => $opts['by'] ?? null,
            'tag' => $opts['tag'] ?? 'snapshot',
            'events' => $events,
        ];

        return EnvelopeDecoder::decode([$delta], $sourceSystem, $legacyEntity, $opts);
    }

    /** field[:locale][:source], following the medipim key grammar the decoder parses back. */
    private static function key(string $field, ?string $locale, ?string $source): string
    {
        $key = $field;
        if ($locale !== null) {
            $key .= ':'.$locale;
        }
        if ($source !== null) {
            $key .= ':'.$source;
        }

        return $key;
    }
}
