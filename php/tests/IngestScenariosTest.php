<?php

declare(strict_types=1);

namespace Ingot\Tests;

use Ingot\Api;
use Ingot\ClaimMapping;
use Ingot\EnvelopeLoader;
use Ingot\Events;
use Ingot\Lanes;
use Ingot\LegacyXref;
use Ingot\MigrationDiff;
use Ingot\PublicId;
use Ingot\Rederivation;
use Ingot\Sets;
use PHPUnit\Framework\TestCase;

/**
 * Ported from test/ingest/rederive_test.exs, legacy_xref_test.exs, migration_diff_test.exs and
 * ingest_walkthrough_test.exs: the synthetic merge / split / collision scenarios + the real
 * 422156 stable case, end-to-end through Rederivation / LegacyXref / MigrationDiff.
 */
final class IngestScenariosTest extends TestCase
{
    private const FIXTURE = __DIR__.'/../../test/ingest/fixtures/medipim_be_422156.json';

    private function envelope(int $entity, array $events): array
    {
        [$ok, $env] = EnvelopeLoader::fromMap(['schema_version' => '1', 'legacy_entity' => $entity, 'events' => $events]);
        self::assertSame('ok', $ok);

        return $env;
    }

    private function id(string $source, string $op, string $scheme, string $code, int $at): array
    {
        return ['recorded_at' => $at, 'source' => $source, 'op' => $op, 'kind' => 'identity', 'scheme' => $scheme, 'code' => $code];
    }

    private function findingFor(array $report, mixed $entity): ?array
    {
        foreach ($report['findings'] as $f) {
            if (($f['legacy_entity'] ?? null) === $entity) {
                return $f;
            }
        }

        return null;
    }

    // ── real 422156: stable / confirmed ──────────────────────────────────────────

    public function test_422156_re_derives_to_one_key_and_log_folds(): void
    {
        $env = EnvelopeLoader::loadBang(self::FIXTURE);
        $result = Rederivation::run([$env], 1);

        self::assertCount(1, $result['clusters']);
        $product = Lanes::partitionMembers($result['ledger']->members)['product'];
        self::assertSame(['SK_1'], array_keys($product));

        self::assertSame('SK_1', Api::resolveKey($result['log'], ['cnk', '3612173']));
        self::assertSame('SK_1', Api::resolveKey($result['log'], ['gtin', '03282770146004']));
        // an alias GTIN width canonicalizes to the same member
        self::assertSame('SK_1', Api::resolveKey($result['log'], ['gtin', '3282770146004']));
        self::assertSame([], PublicId::collisions('cnk', $result['log']));
    }

    public function test_422156_identity_events_continue_after_max_claim_order(): void
    {
        $env = EnvelopeLoader::loadBang(self::FIXTURE);
        $log = Rederivation::run([$env], 1)['log'];

        $maxClaimOrder = -1;
        $identity = [];
        foreach ($log as $e) {
            if ($e instanceof \Ingot\Claim) {
                $maxClaimOrder = max($maxClaimOrder, $e->order);
            } else {
                $identity[] = $e;
            }
        }
        foreach ($identity as $e) {
            self::assertGreaterThan($maxClaimOrder, $e->order());
        }
        self::assertSame($identity, Api::changesSince($log, $maxClaimOrder));
    }

    public function test_422156_xref_is_stable_on_sk1(): void
    {
        $env = EnvelopeLoader::loadBang(self::FIXTURE);
        $xref = LegacyXref::fromEnvelopes([$env], 1);
        self::assertSame(['primary' => 'SK_1', 'all' => ['SK_1'], 'relation' => 'stable'], $xref['legacy_to_key']['i:422156']);
    }

    public function test_422156_diff_is_confirmed_stable(): void
    {
        $env = EnvelopeLoader::loadBang(self::FIXTURE);
        $report = MigrationDiff::fromEnvelopes([$env], 1);
        $f = $this->findingFor($report, 422156);
        self::assertSame('confirmed', $f['category']);
        self::assertSame('stable', $f['relation']);
    }

    // ── merge: two entities sharing a national CNK ────────────────────────────────

    public function test_merge_shared_cnk_is_trusted_high_confidence(): void
    {
        $envs = [
            $this->envelope(1, [$this->id('A', 'set', 'cnk', '100', 10)]),
            $this->envelope(2, [$this->id('B', 'set', 'cnk', '100', 10)]),
        ];
        $report = MigrationDiff::fromEnvelopes($envs, 1);

        foreach ([1, 2] as $entity) {
            $f = $this->findingFor($report, $entity);
            self::assertSame('merged', $f['category']);
            self::assertSame('high', $f['confidence']);
            self::assertFalse($f['needs_review']);
        }

        // re-derivation: one key, one mint
        $result = Rederivation::run($envs, 1);
        self::assertCount(1, $result['clusters']);
        self::assertSame('SK_1', Api::resolveKey($result['log'], ['cnk', '100']));
    }

    // ── split: one entity with disjoint codes ─────────────────────────────────────

    public function test_split_disjoint_codes_fragments_across_two_keys(): void
    {
        $envs = [
            $this->envelope(700, [
                $this->id('A', 'set', 'cnk', '555', 10),
                $this->id('B', 'set', 'gtin', '05012345678900', 10),
            ]),
        ];
        $report = MigrationDiff::fromEnvelopes($envs, 1);
        $f = $this->findingFor($report, 700);
        self::assertSame('split', $f['category']);
        self::assertCount(2, $f['keys']);
        self::assertSame(1, $report['counts']['split']);
    }

    // ── shared (in-store) GTIN rides along but never bridges ──────────────────────

    public function test_shared_gtin_rides_but_never_bridges(): void
    {
        $envs = [
            $this->envelope(30, [$this->id('A', 'set', 'cnk', '300', 10), $this->id('A', 'add', 'gtin', '02000000000017', 11)]),
            $this->envelope(40, [$this->id('B', 'set', 'cnk', '400', 10), $this->id('B', 'add', 'gtin', '02000000000017', 11)]),
        ];

        $built = ClaimMapping::build($envs);
        self::assertSame([['gtin', '02000000000017']], Sets::values($built['shared']));

        $result = Rederivation::fromClaims($built, 1);
        self::assertCount(2, $result['clusters']);
        $keys = array_keys($result['ledger']->members);
        sort($keys);
        self::assertSame(['SK_1', 'SK_2'], $keys);
        foreach ($result['ledger']->members as $codes) {
            self::assertTrue(Sets::member($codes, ['gtin', '02000000000017']));
        }
    }

    // ── collision: a CNK on two keys (hand-assembled) ─────────────────────────────

    public function test_collision_cnk_on_two_keys_needs_review(): void
    {
        $log = [
            Events::identityMinted('SK_1', Sets::of([['cnk', '777']]), 10),
            Events::identityMinted('SK_2', Sets::of([['cnk', '777']]), 10),
        ];
        $report = MigrationDiff::render([], PublicId::collisions('cnk', $log));

        $f = null;
        foreach ($report['findings'] as $finding) {
            if ($finding['category'] === 'collision') {
                $f = $finding;
            }
        }
        self::assertNotNull($f);
        self::assertTrue($f['needs_review']);
        self::assertSame('cnk:777', $f['code']);
        self::assertSame(1, $report['counts']['collision']);
    }
}
