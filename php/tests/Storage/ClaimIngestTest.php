<?php

declare(strict_types=1);

namespace Ingot\Tests\Storage;

use Ingot\Api;
use Ingot\ClaimMapping;
use Ingot\Catalog;
use Ingot\Codes;
use Ingot\IdentityLedger;
use Ingot\EnvelopeLoader;
use Ingot\Events;
use Ingot\Priority;
use Ingot\SnapshotTranslator;
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

    /** @return array<string,mixed> the raw contract-C map (flat payload keys, as EnvelopeLoader::fromMap expects) */
    private function rawMap(int $entity, array $events): array
    {
        return ['schema_version' => '1', 'source_system' => 'medipim-be', 'legacy_entity' => $entity, 'events' => $events];
    }

    private function envelope(int $entity, array $events): \Ingot\Envelope
    {
        [$ok, $env] = EnvelopeLoader::fromMap($this->rawMap($entity, $events));
        self::assertSame('ok', $ok);

        return $env;
    }

    private function id(string $source, string $op, string $scheme, ?string $code, int $at): array
    {
        return ['recorded_at' => $at, 'source' => $source, 'op' => $op, 'kind' => 'identity', 'scheme' => $scheme, 'code' => $code];
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
        self::assertSame('SK_1', Api::resolveKey(Events::fromArrays($store->log()), ['cnk', '3612173']));
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
            if (($c->data['code'] ?? null) === $departed) {
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
            $ledger = IdentityLedger::evolve($ledger, $event instanceof \Ingot\DomainEvent ? $event : Events::fromArray($event));
        }

        $claims = [];
        foreach ($log as $event) {
            if (is_array($event) && ($event['type'] ?? null) === null && isset($event['kind'])) {
                $claims[] = $event;
            }
        }

        return Catalog::project($ledger->members, Substrate::current($claims), Priority::new([], []), ['attr' => [], 'product' => []]);
    }

    public function test_live_full_delisting_retracts_the_key(): void
    {
        // gr-iy5: a live envelope whose listing clears every code must retract the key and drop
        // its member rows — the previous codes live only in the batch's EARLIER periods, which is
        // why the subgraph load anchors on the uncompacted claims.
        $store = new InMemoryClaimStore();
        $listing = static fn (array $events): array => ['schema_version' => '1', 'legacy_entity' => 9001, 'events' => $events];
        $set = ['recorded_at' => 10, 'source' => 'A', 'op' => 'set', 'kind' => 'identity', 'scheme' => 'cnk', 'code' => '111'];
        $clear = ['recorded_at' => 2 * 86_400, 'source' => 'A', 'op' => 'set', 'kind' => 'identity', 'scheme' => 'cnk', 'code' => null];

        ClaimIngest::live($store, [$listing([$set])]);
        $cnk = Codes::key(Codes::canonicalize(['cnk', '111']));
        $key = $store->resolveKey($cnk);
        self::assertNotNull($key);

        ClaimIngest::live($store, [$listing([$set, $clear])]);

        self::assertNull($store->resolveKey($cnk), 'a fully delisted key must stop resolving');
        self::assertSame([], $store->loadKeys([$key]), 'the retired snapshot must be gone');
        $types = array_column($store->log(), 'type');
        self::assertContains(Events::TYPE_IDENTITY_RETRACTED, $types);

        // re-running the same truth leaves the converged state untouched
        ClaimIngest::live($store, [$listing([$set, $clear])]);
        self::assertNull($store->resolveKey($cnk));
        self::assertSame([], $store->loadKeys([$key]));
    }

    // ── durable shared-codes map (gh-119) ────────────────────────────────────────

    public function test_backfill_persists_the_batchs_shared_codes(): void
    {
        // The restricted-GTIN fixture from ClaimMappingTest::test_restricted_gtin_lands_in_shared.
        $events = [
            $this->id('A', 'add', 'gtin', '02000000000000', 10),
            $this->id('A', 'set', 'cnk', '111', 20),
        ];
        $env = $this->envelope(1, $events);

        $store = new InMemoryClaimStore();
        ClaimIngest::backfill($store, [$this->rawMap(1, $events)]);

        self::assertSame(
            ClaimMapping::build([$env])['shared'],
            $store->allShared(),
        );
    }

    public function test_shared_codes_accumulate_add_only_across_separate_backfills(): void
    {
        $store = new InMemoryClaimStore();

        ClaimIngest::backfill($store, [$this->rawMap(1, [
            $this->id('A', 'add', 'gtin', '02000000000017', 10),
            $this->id('A', 'set', 'cnk', '111', 20),
        ])]);

        ClaimIngest::backfill($store, [$this->rawMap(2, [
            $this->id('B', 'set', 'artg_id', '207479', 10),
            $this->id('B', 'add', 'ean', '9338475000364', 10),
        ])]);

        $shared = $store->allShared();
        self::assertArrayHasKey(Codes::key(['gtin', '02000000000017']), $shared, 'the first backfill\'s shared code must survive the second');
        self::assertArrayHasKey(Codes::key(['artg_id', '207479']), $shared);
    }

    // ── durable legacy xref (gh-120) ─────────────────────────────────────────────

    public function test_backfill_records_a_resolvable_legacy_xref(): void
    {
        $store = new InMemoryClaimStore();
        ClaimIngest::backfill($store, [self::rawEnvelope()]);

        self::assertSame('SK_1', $store->resolveLegacy('medipim-be', '422156'));
    }

    public function test_live_records_a_resolvable_legacy_xref(): void
    {
        $store = new InMemoryClaimStore();
        ClaimIngest::live($store, [self::rawEnvelope()]);

        self::assertSame('SK_1', $store->resolveLegacy('medipim-be', '422156'));
    }

    public function test_xref_tracks_the_current_key_across_separate_ingests(): void
    {
        $store = new InMemoryClaimStore();

        ClaimIngest::backfill($store, [$this->rawMap(1, [$this->id('A', 'set', 'cnk', '100', 10)])]);
        self::assertNotNull($store->resolveLegacy('medipim-be', '1'));

        // Entity 2 shares the same national CNK, established by entity 1's earlier backfill —
        // it extends that same key rather than minting its own.
        ClaimIngest::backfill($store, [$this->rawMap(2, [$this->id('B', 'set', 'cnk', '100', 10)])]);

        $skAfter1 = $store->resolveLegacy('medipim-be', '1');
        $skAfter2 = $store->resolveLegacy('medipim-be', '2');
        self::assertSame($skAfter1, $skAfter2, 'both legacy entities must resolve to the same current key');
    }

    public function test_xref_follows_an_addRedirect_merge(): void
    {
        // A real steward-approved merge is gated behind human review and out of ClaimIngest's own
        // reconcile loop (established keys are never auto-merged), so this drives the store-level
        // primitive ClaimIngest::reproject already calls on an IdentitiesMerged event — proving the
        // xref rows it wrote earlier stay resolvable to the surviving key.
        $store = new InMemoryClaimStore();

        $env = self::rawEnvelope();
        ClaimIngest::backfill($store, [$env]);
        $before = $store->resolveLegacy('medipim-be', '422156');
        self::assertNotNull($before);

        $store->addRedirect($before, 'SK_999', 1_700_000_000);

        self::assertSame('SK_999', $store->resolveLegacy('medipim-be', '422156'));
    }

    public function test_envelope_with_no_resolvable_identity_leaves_no_dangling_xref(): void
    {
        // An unsourced attribute-only envelope carries no identity code at all — nothing to anchor
        // an xref row to, so none must be written rather than a dangling one.
        $raw = [
            'schema_version' => '1',
            'source_system' => 'medipim-be',
            'legacy_entity' => 555,
            'events' => [
                ['recorded_at' => 10, 'source' => null, 'op' => 'set', 'kind' => 'attribute', 'field' => 'name', 'value' => 'Orphan'],
            ],
        ];

        $store = new InMemoryClaimStore();
        ClaimIngest::live($store, [$raw]);

        self::assertNull($store->resolveLegacy('medipim-be', '555'));
    }

    // ── claim-shape fingerprint version (medipimv2-sgh.12) ────────────────────────

    public function test_envelope_fingerprint_is_derived_from_the_claim_shape_version(): void
    {
        $env = $this->envelope(1, [$this->id('A', 'set', 'cnk', '111', 10)]);

        $expected = hash('sha256', \Ingot\ClaimShape::VERSION."\n".json_encode($env->toArray(), JSON_THROW_ON_ERROR));
        self::assertSame($expected, ClaimIngest::envelopeFingerprint($env));
    }

    public function test_envelope_fingerprint_would_differ_across_claim_shape_versions(): void
    {
        // Proves the version is actually mixed into the hash (not just declared): a differently
        // versioned fingerprint of the SAME envelope payload must differ, or a claim-shape change
        // would silently skip previously-seen entities via backfill_seen.
        $env = $this->envelope(1, [$this->id('A', 'set', 'cnk', '111', 10)]);
        $payload = json_encode($env->toArray(), JSON_THROW_ON_ERROR);

        self::assertNotSame(
            hash('sha256', '1'."\n".$payload),
            hash('sha256', \Ingot\ClaimShape::VERSION."\n".$payload),
        );
        self::assertSame(hash('sha256', \Ingot\ClaimShape::VERSION."\n".$payload), ClaimIngest::envelopeFingerprint($env));
    }

    public function test_schema_statements_apply_the_prefix(): void
    {
        $statements = Schema::statements('gr_');
        self::assertCount(8, $statements);

        $all = implode("\n", $statements);
        self::assertStringContainsString('`gr_events`', $all);
        self::assertStringContainsString('`gr_snapshots`', $all);
        self::assertStringContainsString('`gr_members`', $all);
        self::assertStringContainsString('`gr_redirects`', $all);
        self::assertStringContainsString('`gr_lane_seq`', $all);
        self::assertStringContainsString('`gr_backfill_seen`', $all);
        self::assertStringContainsString('`gr_shared`', $all);
        self::assertStringContainsString('`gr_legacy_xref`', $all);
    }

    // ── the envelope actor lands on claim rows (gh-132) ──────────────────────────

    private function attr(string $source, string $field, mixed $value, int $at, mixed $by = null): array
    {
        return ['recorded_at' => $at, 'source' => $source, 'op' => 'set', 'kind' => 'attribute', 'field' => $field, 'value' => $value, 'by' => $by];
    }

    public function test_claim_rows_persist_the_actor_the_envelope_carried(): void
    {
        $store = new InMemoryClaimStore();
        $day = 86_400;
        ClaimIngest::live($store, [$this->rawMap(7001, [
            $this->id('A', 'set', 'cnk', '111', $day) + ['by' => 42],
            $this->attr('A', 'name', 'x', $day, 42),
        ])]);

        $claims = array_values(array_filter($store->log(), static fn (array $e): bool => $e['type'] === Events::TYPE_CLAIM_ASSERTED));
        self::assertNotEmpty($claims);
        foreach ($claims as $c) {
            self::assertSame(42, $c['by'], $c['kind'].' claim row must carry the actor');
        }
        // and the boundary codec round-trips it
        self::assertSame(42, Events::fromArray($claims[0])->by);
    }

    public function test_a_different_actor_re_asserting_identical_content_is_still_a_no_op(): void
    {
        // `by` is provenance, not content: the winnow identity stays {source, kind, data, valid_from}.
        $store = new InMemoryClaimStore();
        $day = 86_400;
        $events = static fn (mixed $by): array => [['recorded_at' => $day, 'source' => 'A', 'op' => 'set', 'kind' => 'identity', 'scheme' => 'cnk', 'code' => '111', 'by' => $by]];

        ClaimIngest::live($store, [$this->rawMap(7002, $events(1))]);
        $seq = $store->maxSeq();
        $second = ClaimIngest::live($store, [$this->rawMap(7002, $events(2))]);

        self::assertSame(0, $second['appended']);
        self::assertSame($seq, $store->maxSeq());
    }

    // ── a now-envelope replaces the listing's assertion set (gh-131) ─────────────

    private function edge(string $source, string $collection, mixed $member, int $at): array
    {
        return ['recorded_at' => $at, 'source' => $source, 'op' => 'add', 'kind' => 'edge', 'collection' => $collection, 'value' => $member];
    }

    /** @return list<array<string,mixed>> the current claim view of the key a code resolves to */
    private static function view(InMemoryClaimStore $store, string $codeKey): array
    {
        $key = $store->resolveKey($codeKey);
        self::assertNotNull($key);

        return $store->loadKeys([$key])[$key]['claims'];
    }

    /** @return array<string,mixed> field => value */
    private static function fields(InMemoryClaimStore $store, string $codeKey): array
    {
        $out = [];
        foreach (self::view($store, $codeKey) as $c) {
            if ($c['kind'] === 'attribute') {
                $out[$c['data']['field']] = $c['data']['value'];
            }
        }
        ksort($out);

        return $out;
    }

    /** @return list<string> "from→to" per edge of $relation, sorted */
    private static function edges(InMemoryClaimStore $store, string $codeKey, string $relation): array
    {
        $out = [];
        foreach (self::view($store, $codeKey) as $c) {
            if ($c['kind'] === 'edge' && $c['data']['relation'] === $relation) {
                $out[] = implode(':', $c['data']['from']).'→'.implode(':', $c['data']['to']);
            }
        }
        sort($out);

        return $out;
    }

    public function test_live_omitting_an_attribute_retracts_it_like_a_backfilled_null_set(): void
    {
        $day = 86_400;
        $cnk = Codes::key(Codes::canonicalize(['cnk', '111']));
        $set = $this->id('A', 'set', 'cnk', '111', $day);

        $live = new InMemoryClaimStore();
        ClaimIngest::live($live, [$this->rawMap(8001, [$set, $this->attr('A', 'name', 'A', $day), $this->attr('A', 'dosage', '500mg', $day)])]);
        self::assertSame(['dosage' => '500mg', 'name' => 'A'], self::fields($live, $cnk));

        $omitting = $this->rawMap(8001, [$set, $this->attr('A', 'name', 'A', 2 * $day)]);
        ClaimIngest::live($live, [$omitting]);
        self::assertSame(['dosage' => null, 'name' => 'A'], self::fields($live, $cnk), 'an omitted attribute is retracted');

        // the same history as a backfill that nulls the field folds to the same current truth
        $backfill = new InMemoryClaimStore();
        ClaimIngest::backfill($backfill, [$this->rawMap(8001, [
            $set, $this->attr('A', 'name', 'A', $day), $this->attr('A', 'dosage', '500mg', $day), $this->attr('A', 'dosage', null, 2 * $day),
        ])]);
        self::assertSame(self::fields($backfill, $cnk), self::fields($live, $cnk));

        // converged: the same truth again is a no-op
        $seq = $live->maxSeq();
        self::assertSame(0, ClaimIngest::live($live, [$omitting])['appended']);
        self::assertSame($seq, $live->maxSeq());
    }

    public function test_live_collection_members_land_and_an_omitted_member_is_retracted(): void
    {
        $day = 86_400;
        $cnk = Codes::key(Codes::canonicalize(['cnk', '111']));
        $set = $this->id('A', 'set', 'cnk', '111', $day);
        $store = new InMemoryClaimStore();

        ClaimIngest::live($store, [$this->rawMap(8002, [$set, $this->edge('A', 'brands', 9, $day), $this->edge('A', 'brands', 12, $day)])]);
        self::assertSame(['cnk:111→brands:12', 'cnk:111→brands:9'], self::edges($store, $cnk, 'member_of'), 'members land on the live path');

        $only9 = $this->rawMap(8002, [$set, $this->edge('A', 'brands', 9, 2 * $day)]);
        ClaimIngest::live($store, [$only9]);
        self::assertSame(['cnk:111→brands:9'], self::edges($store, $cnk, 'member_of'), 'an omitted member is retracted');

        // the log keeps the retraction as an audit row; the current view dropped the slot
        $markers = array_values(array_filter(
            $store->log(),
            static fn (array $e): bool => $e['type'] === Events::TYPE_CLAIM_ASSERTED && $e['kind'] === 'edge' && ($e['data']['retracted'] ?? false) === true,
        ));
        self::assertCount(1, $markers);
        self::assertSame(['brands', '12'], $markers[0]['data']['to']);

        $seq = $store->maxSeq();
        self::assertSame(0, ClaimIngest::live($store, [$only9])['appended'], 'the same truth again is a no-op');
        self::assertSame($seq, $store->maxSeq());

        // re-asserting the member wins the slot back
        ClaimIngest::live($store, [$this->rawMap(8002, [$set, $this->edge('A', 'brands', 9, 3 * $day), $this->edge('A', 'brands', 12, 3 * $day)])]);
        self::assertSame(['cnk:111→brands:12', 'cnk:111→brands:9'], self::edges($store, $cnk, 'member_of'));
    }

    private function media(string $source, int $asset, int $at): array
    {
        return ['recorded_at' => $at, 'source' => $source, 'op' => 'add', 'kind' => 'media', 'collection' => 'media', 'asset' => $asset];
    }

    public function test_a_media_entitys_own_snapshot_does_not_retract_the_edges_its_products_own(): void
    {
        // depicts/describes edges are asserted by the PRODUCT's envelope and stored on the
        // product's key (gr-vas); an asset's own snapshot carries fields only and must leave them.
        $day = 86_400;
        $store = new InMemoryClaimStore();
        $cnk = Codes::key(Codes::canonicalize(['cnk', '111']));
        ClaimIngest::live($store, [$this->rawMap(8003, [$this->id('A', 'set', 'cnk', '111', $day), $this->media('A', 158717, $day)])]);

        $before = self::edges($store, $cnk, 'depicts');
        self::assertSame(['asset_id:158717→cnk:111'], $before);

        $asset = Codes::key(Codes::canonicalize(['asset_id', '158717']));
        $own = SnapshotTranslator::toEnvelope([['source' => 'A', 'fields' => ['uri' => 'x']]], 'medipim-be', 158717, 2 * $day, ['identity_scheme' => 'asset_id']);
        ClaimIngest::live($store, [$own]);

        self::assertSame($before, self::edges($store, $cnk, 'depicts'));
        self::assertSame(['x'], array_values(self::fields($store, $asset)), 'its own field landed');
    }

    public function test_a_product_dropping_a_media_asset_retracts_its_depicts_edge(): void
    {
        // gr-vas: the edge lives on the product's key, so the product's own now-envelope reaches
        // it even though the asset is no longer in the batch. The asset itself is orphaned, not
        // deleted.
        $day = 86_400;
        $store = new InMemoryClaimStore();
        $cnk = Codes::key(Codes::canonicalize(['cnk', '111']));
        $asset = Codes::key(Codes::canonicalize(['asset_id', '158717']));
        $set = $this->id('A', 'set', 'cnk', '111', $day);

        ClaimIngest::live($store, [$this->rawMap(8004, [$set, $this->media('A', 158717, $day), $this->media('A', 158718, $day)])]);
        self::assertSame(['asset_id:158717→cnk:111', 'asset_id:158718→cnk:111'], self::edges($store, $cnk, 'depicts'));

        $only18 = $this->rawMap(8004, [$set, $this->media('A', 158718, 2 * $day)]);
        ClaimIngest::live($store, [$only18]);
        self::assertSame(['asset_id:158718→cnk:111'], self::edges($store, $cnk, 'depicts'), 'the dropped asset\'s edge is retracted');
        self::assertNotNull($store->resolveKey($asset), 'the asset record stays (orphaned, not deleted)');

        $seq = $store->maxSeq();
        self::assertSame(0, ClaimIngest::live($store, [$only18])['appended'], 'the same truth again is a no-op');
        self::assertSame($seq, $store->maxSeq());

        // re-listing the asset wins the edge back
        ClaimIngest::live($store, [$this->rawMap(8004, [$set, $this->media('A', 158717, 3 * $day), $this->media('A', 158718, 3 * $day)])]);
        self::assertSame(['asset_id:158717→cnk:111', 'asset_id:158718→cnk:111'], self::edges($store, $cnk, 'depicts'));
    }
}
