<?php

declare(strict_types=1);

namespace Ingot\Tests\Storage;

use Ingot\Api;
use Ingot\ClaimMapping;
use Ingot\Catalog;
use Ingot\Codes;
use Ingot\IdentityLedger;
use Ingot\EnvelopeLoader;
use Ingot\Priority;
use Ingot\Substrate;
use Ingot\Storage\ClaimIngest;
use Ingot\Storage\InMemoryClaimStore;
use Ingot\Storage\Schema;
use PHPUnit\Framework\TestCase;

/**
 * The persistent writer over the in-memory {@see ClaimStore}: backfill mints + resolves the same
 * keys the from-zero fold does, the appended log is a valid engine log, and both paths are
 * idempotent (backfill per envelope, live per slot).
 */
final class ClaimIngestTest extends TestCase
{
    private const FIXTURE = __DIR__.'/../../../test/ingest/fixtures/medipim_be_422156.json';

    private static function cnkKey(): string
    {
        return Codes::key(Codes::canonicalize(['cnk', '3612173']));
    }

    /** The raw envelope MAP (as the decoder / fixture emits it); ClaimIngest loads it internally. */
    private static function rawEnvelope(): array
    {
        return json_decode(file_get_contents(self::FIXTURE), true, 512, JSON_THROW_ON_ERROR);
    }

    public function test_backfill_mints_sk1_and_resolves_the_cnk(): void
    {
        $store = new InMemoryClaimStore();
        $env = self::rawEnvelope();

        $summary = ClaimIngest::backfill($store, [$env]);

        self::assertSame(1, $summary['accepted']);
        self::assertGreaterThan(0, $summary['appended']);

        self::assertSame('SK_1', $store->resolveKey(self::cnkKey()));
        $loaded = $store->loadKeys(['SK_1']);
        self::assertArrayHasKey('SK_1', $loaded);
        self::assertArrayHasKey(self::cnkKey(), $loaded['SK_1']['codes']);
    }

    public function test_appended_log_is_a_valid_engine_log(): void
    {
        $store = new InMemoryClaimStore();
        ClaimIngest::backfill($store, [self::rawEnvelope()]);

        // Folding the appended log from zero via the read-side Api resolves the product to SK_1.
        self::assertSame('SK_1', Api::resolveKey($store->log(), ['cnk', '3612173']));
    }

    public function test_backfill_is_idempotent_per_envelope(): void
    {
        $store = new InMemoryClaimStore();
        $env = self::rawEnvelope();

        ClaimIngest::backfill($store, [$env]);
        $afterFirst = $store->maxSeq();

        $second = ClaimIngest::backfill($store, [$env]);
        self::assertSame(0, $second['accepted']);
        self::assertSame(1, $second['skipped']);
        self::assertSame(0, $second['appended']);
        self::assertSame($afterFirst, $store->maxSeq(), 'a replayed envelope must append nothing');
    }

    public function test_live_is_idempotent_per_slot(): void
    {
        $store = new InMemoryClaimStore();
        $env = self::rawEnvelope();

        $first = ClaimIngest::live($store, [$env]);
        self::assertGreaterThan(0, $first['appended']);
        $afterFirst = $store->maxSeq();

        $second = ClaimIngest::live($store, [$env]);
        self::assertSame(0, $second['appended'], 'an unchanged live write must be a no-op');
        self::assertSame($afterFirst, $store->maxSeq());

        self::assertSame('SK_1', $store->resolveKey(self::cnkKey()));
    }

    public function test_a_claim_on_a_departed_code_is_dropped_from_live_and_changes_nothing(): void
    {
        // gr-xfw. Listing 44 carried gtin:03282770049374 and the barcode later moved. Since claims
        // carry intervals, compaction keeps the last claim for that slot even though no identity
        // asserts the code any more.
        //
        // Dropping it from the live write is safe because the claim is ALREADY unreachable: an
        // attribute reaches a product only via Survivorship, which keeps attributes whose code is
        // in an identity's member set. Prove that rather than assert it — the projection must be
        // identical whether or not the departed claims are present.
        $departed = ['gtin', '03282770049374'];

        $store = new InMemoryClaimStore();
        ClaimIngest::live($store, [self::rawEnvelope()]);
        $log = $store->log();
        $withoutDeparted = self::project($log);

        $env = EnvelopeLoader::loadBang(self::FIXTURE);
        $reintroduced = [];
        foreach (Substrate::current(ClaimMapping::build([$env])['claims']) as $c) {
            if (($c['data']['code'] ?? null) === $departed) {
                $reintroduced[] = $c;
            }
        }
        self::assertNotEmpty($reintroduced, 'fixture no longer exercises a departed code');

        $withDeparted = self::project(array_merge($log, $reintroduced));

        self::assertEquals($withoutDeparted, $withDeparted, 'the departed-code claims change nothing');
    }

    /** Members from the log's identity events, then the catalogue projection over them. */
    private static function project(array $log): array
    {
        $ledger = IdentityLedger::new();
        foreach ($log as $event) {
            $ledger = IdentityLedger::evolve($ledger, $event);
        }

        $claims = [];
        foreach ($log as $event) {
            if (($event['type'] ?? null) === null && isset($event['kind'])) {
                $claims[] = $event;
            }
        }

        return Catalog::project($ledger->members, Substrate::current($claims), Priority::new([], []), ['attr' => [], 'product' => []]);
    }

    public function test_schema_statements_apply_the_prefix(): void
    {
        $statements = Schema::statements('gr_');
        self::assertCount(6, $statements);

        $all = implode("\n", $statements);
        self::assertStringContainsString('`gr_events`', $all);
        self::assertStringContainsString('`gr_snapshots`', $all);
        self::assertStringContainsString('`gr_members`', $all);
        self::assertStringContainsString('`gr_redirects`', $all);
        self::assertStringContainsString('`gr_lane_seq`', $all);
        self::assertStringContainsString('`gr_backfill_seen`', $all);
    }
}
