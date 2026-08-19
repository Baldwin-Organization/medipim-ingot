<?php

declare(strict_types=1);

namespace Ingot\Tests;

use Ingot\Codes;
use Ingot\SnapshotTranslator;
use Ingot\Storage\ClaimIngest;
use Ingot\Storage\InMemoryClaimStore;
use PHPUnit\Framework\TestCase;

/**
 * The live translator turns a current-truth snapshot into a "now" envelope that ingests through the
 * same machinery as backfill, and an unchanged re-ingest is a no-op.
 */
final class SnapshotTranslatorTest extends TestCase
{
    private static function cnkKey(): string
    {
        return Codes::key(Codes::canonicalize(['cnk', '3612173']));
    }

    public function test_product_snapshot_ingests_and_resolves(): void
    {
        $store = new InMemoryClaimStore();
        $snapshot = [[
            'source' => '1034',
            'fields' => ['cnk' => '3612173', 'status' => 'active', 'name' => ['nl' => 'Wasgel', 'fr' => 'Gel']],
            'collections' => ['media' => [158717], 'brands' => [9]],
        ]];

        $envelope = SnapshotTranslator::toEnvelope($snapshot, 'medipim-be', 422156, 1_700_000_000);
        $summary = ClaimIngest::live($store, [$envelope]);

        self::assertGreaterThan(0, $summary['appended']);
        self::assertSame('SK_1', $store->resolveKey(self::cnkKey()));

        // A media collection member mints a media-lane record.
        self::assertNotNull($store->resolveKey(Codes::key(Codes::canonicalize(['asset_id', '158717']))));
    }

    public function test_re_ingesting_the_same_snapshot_is_a_no_op(): void
    {
        $store = new InMemoryClaimStore();
        $snapshot = [[
            'source' => '1034',
            'fields' => ['cnk' => '3612173', 'status' => 'active'],
        ]];

        $envelope = SnapshotTranslator::toEnvelope($snapshot, 'medipim-be', 422156, 1_700_000_000);
        ClaimIngest::live($store, [$envelope]);
        $afterFirst = $store->maxSeq();

        $again = ClaimIngest::live($store, [$envelope]);
        self::assertSame(0, $again['appended']);
        self::assertSame($afterFirst, $store->maxSeq());
    }

    public function test_description_snapshot_uses_an_injected_lane_identity(): void
    {
        $store = new InMemoryClaimStore();
        $snapshot = [[
            'source' => '1034',
            'fields' => ['title' => ['nl' => 'Bijsluiter']],
        ]];

        $envelope = SnapshotTranslator::toEnvelope(
            $snapshot,
            'medipim-be',
            9001,
            1_700_000_000,
            ['identity_scheme' => 'text_id'],
        );
        $summary = ClaimIngest::live($store, [$envelope]);

        self::assertGreaterThan(0, $summary['appended']);
        // The description mints a DSC-lane key resolvable by its text_id.
        $key = $store->resolveKey(Codes::key(Codes::canonicalize(['text_id', '9001'])));
        self::assertNotNull($key);
        self::assertStringStartsWith('DSC_', $key);
    }

    public function test_collection_members_carry_the_source(): void
    {
        $envelope = SnapshotTranslator::toEnvelope(
            [[
                'source' => '1034',
                'fields' => ['cnk' => '3612173'],
                'collections' => ['brands' => [9]],
            ]],
            'medipim-be',
            422156,
            1_700_000_000,
        );

        $brand = null;
        foreach ($envelope['events'] as $event) {
            if ('edge' === ($event['kind'] ?? null) && 'brands' === ($event['collection'] ?? null)) {
                $brand = $event;
                break;
            }
        }

        self::assertNotNull($brand);
        self::assertSame('1034', $brand['source']);
        self::assertSame(9, $brand['value']);
    }
}
