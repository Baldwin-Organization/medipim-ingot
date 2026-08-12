#!/usr/bin/env php
<?php

declare(strict_types=1);

/**
 * Independent medipim shadow-window oracle.
 *
 * Usage (from the repository root):
 *
 *   php php/bench/dump_medipim_shadow_window.php
 *
 * The input is the real Belgian and French HistoryEnvelope fixtures. The three projections model
 * the API test's exact sequence: baseline cutover, whole-source refresh (current slots replaced),
 * then one later-recorded correction with an older valid_from date.
 *
 * The two engines use different surrogate-key formats, and the HTTP view does not expose the
 * media lane's stable asset code. The oracle therefore compares only semantic common ground:
 * sorted product codes; sorted attribute field/value/winner/status/candidates; active status; and
 * the sorted media source/URI multiset (plus its count). Product/media surrogate keys and API
 * clocks are deliberately excluded. This normalization is also emitted into the generated JSON.
 */

require __DIR__.'/../vendor/autoload.php';

use Ingot\Api;
use Ingot\CanonicalClaims;
use Ingot\ClaimMapping;
use Ingot\EnvelopeLoader;
use Ingot\GoldenRecords;
use Ingot\Priority;
use Ingot\Rederivation;

const TARGET_CODE = 'cnk:3612173';
const REFRESHED_NAME = 'Nom rafraîchi';
const LATE_CORRECTION = 'Correction arrivée en retard';
const BASELINE_RECORDED_AT = '2026-01-01T00:00:00Z';
const REFRESH_RECORDED_AT = '2026-01-02T00:00:00Z';
const LATE_RECORDED_AT = '2026-01-03T00:00:00Z';

/**
 * Mirror Api.E2eMigrationTest.fixed_mapping/0 without calling any Elixir/API implementation.
 *
 * @param list<array<string,mixed>> $envelopes
 * @return list<array<string,mixed>>
 */
function fixedWireClaims(array $envelopes): array
{
    $out = [];

    foreach (ClaimMapping::canonicalClaims($envelopes) as $claim) {
        if ($claim['kind'] === 'member_of' || ($claim['source'] ?? null) === null) {
            continue;
        }
        if ($claim['kind'] === 'attribute' && ($claim['value'] ?? null) === null) {
            continue;
        }
        if (array_key_exists('value', $claim) && is_array($claim['value'])) {
            $claim['value'] = implode(',', array_map(static fn (mixed $value): string => (string) $value, $claim['value']));
        }

        unset($claim['recorded_at']);
        $claim['valid_from'] = gmdate('Y-m-d', (int) $claim['valid_from']);
        $out[] = $claim;
    }

    return $out;
}

/**
 * @param list<array<string,mixed>> $wireClaims
 * @return list<array<string,mixed>>
 */
function engineClaims(array $wireClaims, string $recordedAt): array
{
    $claims = CanonicalClaims::toEngineBang($wireClaims, $recordedAt);

    foreach ($claims as $order => &$claim) {
        $claim['order'] = $order;
    }
    unset($claim);

    return $claims;
}

/**
 * @param list<array<string,mixed>> $claims
 * @param array<string, array{0: string, 1: string}> $shared
 * @return array<string,mixed>
 */
function projectPhase(array $claims, array $shared, string $recordedAt): array
{
    $fold = Rederivation::fromClaims(['claims' => $claims, 'shared' => $shared], $recordedAt);
    $golden = GoldenRecords::project($fold, Priority::new([], []));

    foreach ($golden['records'] as $record) {
        foreach ($record['variants'] as $variant) {
            $codes = array_map(
                static fn (array $code): string => $code[0].':'.$code[1],
                $variant['codes'],
            );

            if (in_array(TARGET_CODE, $codes, true)) {
                return normalizeVariant($variant, Api::identityStatus($golden['log'], $variant['key']));
            }
        }
    }

    throw new RuntimeException('target product '.TARGET_CODE.' was not projected');
}

/**
 * Normalize the PHP projection to the stable subset also available from GET /v1/products/422156.
 *
 * @param array<string,mixed> $variant
 * @param array<string,mixed> $identityStatus
 * @return array<string,mixed>
 */
function normalizeVariant(array $variant, array $identityStatus): array
{
    $codes = array_map(
        static fn (array $code): string => $code[0].':'.$code[1],
        $variant['codes'],
    );
    sort($codes, SORT_STRING);

    $attributes = [];
    foreach ($variant['attributes'] as [$field, $decision]) {
        $candidates = array_map(
            static fn (array $candidate): array => [
                'source' => $candidate[0] === null ? null : (string) $candidate[0],
                'value' => $candidate[1],
            ],
            $decision['candidates'],
        );
        usort($candidates, static fn (array $left, array $right): int => stableKey($left) <=> stableKey($right));

        $attributes[] = [
            'field' => (string) $field,
            'value' => $decision['value'],
            'winner' => $decision['winner'] === null ? null : (string) $decision['winner'],
            'status' => (string) $decision['status'],
            'candidates' => $candidates,
        ];
    }
    usort($attributes, static fn (array $left, array $right): int => strcmp($left['field'], $right['field']));

    $media = array_map(
        static fn (array $item): array => [
            'source' => (string) $item['source'],
            'uri' => $item['uri'],
        ],
        $variant['media'],
    );
    usort($media, static fn (array $left, array $right): int => stableKey($left) <=> stableKey($right));

    return [
        'status' => (string) $identityStatus['status'],
        'codes' => $codes,
        'attributes' => $attributes,
        'media_count' => count($media),
        'media' => $media,
    ];
}

/** Canonical comparison key for JSON-compatible values. */
function stableKey(mixed $value): string
{
    return json_encode(sortObjectKeys($value), JSON_UNESCAPED_SLASHES | JSON_UNESCAPED_UNICODE | JSON_THROW_ON_ERROR);
}

/** Recursively sort object keys while preserving list order. */
function sortObjectKeys(mixed $value): mixed
{
    if (!is_array($value)) {
        return $value;
    }
    if (array_is_list($value)) {
        return array_map(sortObjectKeys(...), $value);
    }

    ksort($value, SORT_STRING);

    return array_map(sortObjectKeys(...), $value);
}

$fixtureRoot = __DIR__.'/../../test/ingest/fixtures';
$envelopes = [
    EnvelopeLoader::loadBang($fixtureRoot.'/medipim_be_422156.json'),
    EnvelopeLoader::loadBang($fixtureRoot.'/medipim_fr_347025.json'),
];

$wireBaseline = fixedWireClaims($envelopes);
$shared = ClaimMapping::build($envelopes)['shared'];
$baselineClaims = engineClaims($wireBaseline, BASELINE_RECORDED_AT);

$wireRefresh = array_map(
    static function (array $claim): array {
        if ($claim['kind'] === 'attribute' && $claim['field'] === 'name:fr') {
            $claim['value'] = REFRESHED_NAME;
        }

        return $claim;
    },
    $wireBaseline,
);
$refreshClaims = engineClaims($wireRefresh, REFRESH_RECORDED_AT);

$lateWire = null;
foreach ($wireRefresh as $claim) {
    if ($claim['kind'] === 'attribute' && $claim['field'] === 'name:fr') {
        $lateWire = $claim;
        break;
    }
}
if ($lateWire === null) {
    throw new RuntimeException('real fixtures did not yield a name:fr claim');
}
$lateWire['value'] = LATE_CORRECTION;
$lateWire['valid_from'] = '2024-01-01';
$lateClaim = CanonicalClaims::toEngineBang([$lateWire], LATE_RECORDED_AT)[0];
$lateClaim['order'] = count($refreshClaims);
$lateClaims = [...$refreshClaims, $lateClaim];

$document = [
    'normalization' => [
        'product_selection' => 'variant carrying '.TARGET_CODE.' (medipim legacy entity 422156)',
        'included' => [
            'active identity status',
            'sorted canonical product codes',
            'sorted attribute field/value/winner/status/candidates',
            'sorted media source/URI multiset and count',
        ],
        'excluded' => [
            'product and media surrogate keys (engine-specific formats)',
            'legacy_id (the HTTP route selector, not a PHP projection field)',
            'known_at/effective_at/merged_from (API transport metadata)',
            'media role (not exposed by the HTTP product view)',
        ],
    ],
    'phases' => [
        'baseline' => projectPhase($baselineClaims, $shared, BASELINE_RECORDED_AT),
        'source_refresh' => projectPhase($refreshClaims, $shared, REFRESH_RECORDED_AT),
        'late_arriving_correction' => projectPhase($lateClaims, $shared, LATE_RECORDED_AT),
    ],
];

echo json_encode(
    sortObjectKeys($document),
    JSON_PRETTY_PRINT | JSON_UNESCAPED_SLASHES | JSON_UNESCAPED_UNICODE | JSON_THROW_ON_ERROR,
).PHP_EOL;
