<?php

declare(strict_types=1);

namespace Ingot\Tests;

use Ingot\Claim;
use Ingot\Cluster;
use Ingot\ConflictFlagged;
use Ingot\Events;
use Ingot\IdentityLedger;
use Ingot\Substrate;
use PHPUnit\Framework\TestCase;

/**
 * PHP parity for test/barcode_bridge_test.exs.
 *
 * A barcode is reassignable, so it must not be the one thing fusing two components that each
 * already carry an identifier of their own. When either side has nothing but barcodes, the join
 * still stands — refusing it would orphan a listing for no gain.
 */
final class BarcodeBridgeTest extends TestCase
{
    private const GTIN = ['gtin', '05012345678900'];

    public function test_a_bare_barcode_listing_attaches_to_an_identified_product(): void
    {
        $clusters = $this->variants([
            $this->listing('A', [['cnk', '1111111'], self::GTIN]),
            $this->listing('B', [self::GTIN]),
        ]);

        self::assertCount(1, $clusters);
    }

    public function test_two_bare_barcode_listings_are_one_product(): void
    {
        $clusters = $this->variants([
            $this->listing('A', [self::GTIN]),
            $this->listing('B', [self::GTIN]),
        ]);

        self::assertCount(1, $clusters);
    }

    public function test_two_packs_with_their_own_references_are_held_apart(): void
    {
        $clusters = $this->variants([
            $this->listing('100g', [self::GTIN, ['supplier_ref', 'AMPP-100g']]),
            $this->listing('30g', [self::GTIN, ['supplier_ref', 'AMPP-30g']]),
        ]);

        self::assertCount(2, $clusters);
    }

    public function test_the_held_barcode_is_reported_as_a_conflict(): void
    {
        $events = IdentityLedger::decide(IdentityLedger::new(), [
            'reconcile',
            $this->variants([
                $this->listing('100g', [self::GTIN, ['supplier_ref', 'AMPP-100g']]),
                $this->listing('30g', [self::GTIN, ['supplier_ref', 'AMPP-30g']]),
            ]),
            'd1',
        ]);

        $flagged = false;
        foreach ($events as $event) {
            if ($event instanceof ConflictFlagged && ($event->subject[0] ?? null) === 'identity_conflict') {
                $flagged = true;
            }
        }
        self::assertTrue($flagged, 'expected the held barcode to be flagged');
    }

    public function test_the_hold_does_not_depend_on_listing_order(): void
    {
        $claims = [
            $this->listing('100g', [self::GTIN, ['supplier_ref', 'AMPP-100g']]),
            $this->listing('30g', [self::GTIN, ['supplier_ref', 'AMPP-30g']]),
        ];

        self::assertCount(2, $this->variants($claims));
        self::assertEquals($this->variants($claims), $this->variants(array_reverse($claims)));
    }

    public function test_trusted_same_evidence_overrides_the_hold(): void
    {
        $clusters = $this->variants([
            $this->listing('100g', [self::GTIN, ['supplier_ref', 'AMPP-100g']]),
            $this->listing('30g', [self::GTIN, ['supplier_ref', 'AMPP-30g']]),
            Substrate::claim('steward', 'identity_evidence', [
                'relation' => 'same',
                'left' => ['supplier_ref', 'AMPP-100g'],
                'right' => ['supplier_ref', 'AMPP-30g'],
            ], 'd1', 'd1'),
        ]);

        self::assertCount(1, $clusters);
    }

    public function test_a_non_barcode_bridge_between_stand_alone_sides_still_fuses(): void
    {
        $clusters = $this->variants([
            $this->listing('A', [['cnk', '1111111'], ['supplier_ref', 'S-9']]),
            $this->listing('B', [['cnk', '1111111'], ['supplier_ref', 'S-4'], self::GTIN]),
        ]);

        self::assertCount(1, $clusters);
    }

    public function test_the_national_code_guard_is_unchanged(): void
    {
        $clusters = $this->variants([
            $this->listing('A', [['cnk', '1111111'], self::GTIN]),
            $this->listing('B', [['cnk', '2222222'], self::GTIN]),
        ]);

        self::assertCount(2, $clusters);
    }

    // ── helpers ──────────────────────────────────────────────────────────────

    /** @param list<array{0: string, 1: string}> $codes */
    private function listing(string $ref, array $codes): Claim
    {
        return Substrate::claim('supplier', 'identity', ['ref' => $ref, 'codes' => $codes], 'd1', 'd1');
    }

    /**
     * @param list<Claim> $claims
     *
     * @return list<array<string, array{0: string, 1: string}>>
     */
    private function variants(array $claims): array
    {
        $stamped = [];
        $i = 1;
        foreach ($claims as $claim) {
            $stamped[] = $claim->withOrder($i++);
        }

        return Cluster::variants(Substrate::current($stamped));
    }
}
