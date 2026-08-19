<?php

declare(strict_types=1);

namespace Ingot\Tests;

use Ingot\Api;
use Ingot\Claim;
use Ingot\Cluster;
use Ingot\Decision;
use Ingot\DomainEvent;
use Ingot\History;
use Ingot\IdentityLedger;
use Ingot\IdentityStatus;
use Ingot\LedgerState;
use Ingot\Priority;
use Ingot\Stewardship;
use Ingot\Substrate;
use Ingot\Variant;
use PHPUnit\Framework\TestCase;

/**
 * Ported from the "history" and "customer API" describe blocks in golden_record_test.exs —
 * the point-in-time contract of `History` (transaction-time travel, valid-time expiry) and the
 * `Api::lookup`/`get` read path over it (GH #121). Dates are real ISO strings here: unlike
 * EngineTest's Date-free path, these ARE compared.
 */
final class HistoryApiTest extends TestCase
{
    private const D1 = '2026-01-10';
    private const D2 = '2026-02-01';

    private Priority $priority;

    protected function setUp(): void
    {
        $this->priority = Priority::new(
            [
                'weight_g' => [['manufacturer'], ['supplier'], ['marketplace']],
                'color' => [['supplier', 'manufacturer', 'marketplace']],
                'product' => [['manufacturer'], ['supplier'], ['marketplace']],
            ],
            [['manufacturer'], ['supplier'], ['marketplace']],
        );
    }

    public function test_transaction_time_travel_shows_the_old_belief(): void
    {
        // Back-dated correction: effective Jan 1, but only recorded on D2.
        [$log] = $this->resolve([
            $this->claim('supplier', 'identity', ['ref' => 'A', 'codes' => [['gtin', '0111']]]),
            $this->claim('manufacturer', 'attribute', ['code' => ['gtin', '0111'], 'field' => 'weight_g', 'value' => 255]),
            $this->claim('manufacturer', 'attribute', ['code' => ['gtin', '0111'], 'field' => 'weight_g', 'value' => 250], '2026-01-01', self::D2),
        ]);

        $asOfD1 = $this->attr($this->findVariant(History::projectAsOf($log, self::D1, $this->priority), ['gtin', '0111']), 'weight_g');
        $now = $this->attr($this->findVariant(History::now($log, $this->priority), ['gtin', '0111']), 'weight_g');

        self::assertSame(255, $asOfD1->value);
        self::assertSame(250, $now->value);
    }

    public function test_a_bounded_claim_expires_at_valid_to(): void
    {
        // color is asserted for [D1, D2) only; the identity itself stays live.
        [$log] = $this->resolve([
            $this->claim('supplier', 'identity', ['ref' => 'A', 'codes' => [['gtin', '0111']]]),
            $this->claim('supplier', 'attribute', ['code' => ['gtin', '0111'], 'field' => 'color', 'value' => 'red'], self::D1, self::D1, self::D2),
        ]);

        $during = $this->findVariant(History::projectValidAsOf($log, self::D1, $this->priority), ['gtin', '0111']);
        self::assertSame('red', $this->attr($during, 'color')->value);

        $after = $this->findVariant(History::projectValidAsOf($log, self::D2, $this->priority), ['gtin', '0111']);
        self::assertNotNull($after, 'the variant itself must survive the attribute expiry');
        self::assertNull($this->maybeAttr($after, 'color'), 'an expired claim must not reach the projection');
    }

    public function test_lookup_by_code_lands_on_the_current_owner_with_an_active_identity(): void
    {
        [$log] = $this->resolve([
            $this->claim('supplier', 'identity', ['ref' => 'A', 'codes' => [['gtin', '0111']]]),
        ]);

        [$status, $record] = Api::lookup($log, ['gtin', '0111'], $this->priority);

        self::assertSame('ok', $status);
        self::assertSame(['status' => 'active'], $record['identity']->toArray());
        self::assertContains(['gtin', '0111'], $record['variant']->codes);
    }

    public function test_lookup_of_an_unknown_code_is_not_found(): void
    {
        [$status, $canon] = Api::lookup([], ['gtin', '0111'], $this->priority);

        self::assertSame('not_found', $status);
        self::assertSame(['gtin', '0111'], $canon);
    }

    public function test_a_stale_merged_key_still_answers_with_a_redirect(): void
    {
        [$log, $ledger] = $this->resolve([
            $this->claim('supplier', 'identity', ['ref' => 'A', 'codes' => [['gtin', '0111']]]),
            $this->claim('supplier', 'identity', ['ref' => 'B', 'codes' => [['gtin', '0222']]]),
        ]);

        $orders = array_map(static fn (DomainEvent $e): ?int => $e->order(), $log);
        [$merge] = $this->stamp(
            Stewardship::approveMerge($ledger->members, ['SK_1', 'SK_2'], 'alice', self::D2),
            max($orders) + 1
        );
        $log2 = array_merge($log, $merge);

        $stale = Api::get($log2, 'SK_2', $this->priority);
        self::assertSame(['status' => 'merged', 'superseded_by' => 'SK_1'], $stale['identity']->toArray());
        self::assertNull($stale['variant'], 'the merged-away key projects no variant of its own');

        $survivor = Api::get($log2, 'SK_1', $this->priority);
        self::assertSame(['status' => 'active'], $survivor['identity']->toArray());
        self::assertContains(['gtin', '0222'], $survivor['variant']->codes);
    }

    // ── helpers (the EngineTest idiom, with real dates) ──────────────────────────

    /** @param array<string,mixed> $data */
    private function claim(string $source, string $kind, array $data, string $vf = self::D1, string $at = self::D1, ?string $vt = null): Claim
    {
        return Substrate::claim($source, $kind, $data, $vf, $at, $vt);
    }

    /**
     * @param list<DomainEvent> $events
     * @return array{0: list<DomainEvent>, 1: int}
     */
    private function stamp(array $events, int $start): array
    {
        $out = [];
        foreach ($events as $e) {
            $out[] = $e->withOrder($start++);
        }

        return [$out, $start];
    }

    /**
     * Single resolution pass -> [log, ledger].
     *
     * @param list<Claim> $claims
     * @return array{0: list<DomainEvent>, 1: LedgerState}
     */
    private function resolve(array $claims): array
    {
        [$c, $o] = $this->stamp($claims, 1);
        $clusters = Cluster::variants(Substrate::current($c), []);
        $res = IdentityLedger::decide(IdentityLedger::new(), ['reconcile', $clusters, self::D1]);
        [$res] = $this->stamp($res, $o);

        $ledger = IdentityLedger::new();
        foreach ($res as $e) {
            $ledger = IdentityLedger::evolve($ledger, $e);
        }

        return [array_merge($c, $res), $ledger];
    }

    /**
     * @param list<\Ingot\GoldenRecord> $records
     * @param array{0: string, 1: string} $code
     */
    private function findVariant(array $records, array $code): ?Variant
    {
        foreach ($records as $r) {
            foreach ($r->variants as $v) {
                if (in_array($code, $v->codes, true)) {
                    return $v;
                }
            }
        }

        return null;
    }

    private function attr(?Variant $variant, string $field): Decision
    {
        $d = $this->maybeAttr($variant, $field);
        self::assertNotNull($d, "expected attribute {$field}");

        return $d;
    }

    private function maybeAttr(?Variant $variant, string $field): ?Decision
    {
        self::assertNotNull($variant);
        foreach ($variant->attributes as [$f, $decision]) {
            if ($f === $field) {
                return $decision;
            }
        }

        return null;
    }
}
