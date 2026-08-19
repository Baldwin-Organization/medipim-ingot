<?php

declare(strict_types=1);

namespace Ingot\Tests\Storage;

use Ingot\EnvelopeLoader;
use Ingot\GoldenRecords;
use Ingot\Storage\ClaimIngest;
use Ingot\Storage\InMemoryClaimStore;
use Ingot\Storage\StoreProjection;
use PHPUnit\Framework\TestCase;

/**
 * The store-backed read side (gh-118): a resolved record per key from the {@see ClaimStore},
 * matching the in-memory envelope fold's survivorship decisions, redirect-aware.
 */
final class StoreProjectionTest extends TestCase
{
    private const FIXTURE = __DIR__.'/../../../test/ingest/fixtures/medipim_be_422156.json';

    private static function backfilled(): InMemoryClaimStore
    {
        $store = new InMemoryClaimStore();
        $raw = json_decode(file_get_contents(self::FIXTURE), true, 512, JSON_THROW_ON_ERROR);
        ClaimIngest::backfill($store, [$raw]);

        return $store;
    }

    public function test_unknown_key_is_null(): void
    {
        self::assertNull(StoreProjection::record(new InMemoryClaimStore(), 'SK_999'));
    }

    public function test_record_matches_the_in_memory_folds_variant(): void
    {
        $store = self::backfilled();
        $record = StoreProjection::record($store, 'SK_1');
        self::assertNotNull($record);
        self::assertSame('SK_1', $record['key']);
        self::assertSame('product', $record['lane']);

        // The same envelope folded fully in memory — the store-backed record must agree with the
        // fold's variant on codes, product resolution, and every field decision.
        $env = EnvelopeLoader::loadBang(self::FIXTURE);
        $variant = null;
        foreach (GoldenRecords::fromEnvelopes([$env], 1)['records'] as $gr) {
            foreach ($gr->variants as $v) {
                if ($v->key === 'SK_1') {
                    $variant = $v;
                }
            }
        }
        self::assertNotNull($variant);

        self::assertSame($variant->codes, $record['codes']);
        self::assertEquals($variant->product, $record['product']);
        self::assertEquals($variant->attributes, $record['attributes']);
        self::assertNotEmpty($record['attributes'], 'fixture must exercise field decisions');
    }

    public function test_record_follows_redirects_to_the_surviving_key(): void
    {
        $store = self::backfilled();
        $sk1 = $store->loadKeys(['SK_1'])['SK_1'];

        // Simulate a steward-approved merge at the store level: SK_1 absorbed into SK_99.
        $store->saveKey('SK_99', $sk1['lane'], $sk1['codes'], $sk1['claims'], $sk1['last_seq']);
        $store->addRedirect('SK_1', 'SK_99', 1_700_000_000);
        $store->removeKey('SK_1');

        $record = StoreProjection::record($store, 'SK_1');
        self::assertNotNull($record);
        self::assertSame('SK_99', $record['key']);
    }

    public function test_policy_is_injected(): void
    {
        $store = self::backfilled();

        // A rank fn is accepted end-to-end (the fixture is single-source per field, so decisions
        // don't change — GoldenRecordsPolicyTest proves ranking semantics; this proves the seam).
        $ranked = StoreProjection::record($store, 'SK_1', static fn (string $dimension, ?string $source): int => 1);
        $default = StoreProjection::record($store, 'SK_1');

        self::assertEquals($default['attributes'], $ranked['attributes']);
    }
}
