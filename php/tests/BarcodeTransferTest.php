<?php

declare(strict_types=1);

namespace Ingot\Tests;

use Ingot\Claim;
use Ingot\Cluster;
use Ingot\ConflictFlagged;
use Ingot\Events;
use Ingot\IdentityLedger;
use Ingot\LedgerState;
use Ingot\Substrate;
use PHPUnit\Framework\TestCase;

/**
 * PHP parity for test/barcode_transfer_test.exs.
 *
 * A barcode is reassignable — NHSBSA publishes a GTIN Transfer Tracking Log of codes moving
 * between dm+d packs — so a surrogate key must never follow one. National codes, assigned once
 * and never reissued, decide which cluster continues the key.
 */
final class BarcodeTransferTest extends TestCase
{
    private const GTIN = ['gtin', '05012345678900'];

    public function test_the_key_stays_with_the_pack_that_keeps_its_national_code(): void
    {
        $ledger = $this->week(IdentityLedger::new(), [
            $this->listing('100g', [['cnk', '1111111'], self::GTIN]),
        ]);

        self::assertSame(['SK_1'], array_keys($ledger->members));

        $ledger = $this->week($ledger, [
            $this->listing('100g', [['cnk', '1111111']]),
            $this->listing('30g', [['cnk', '2222222'], self::GTIN]),
        ]);

        self::assertSame([['cnk', '1111111']], $this->codes($ledger, 'SK_1'));
        self::assertSame(
            [['cnk', '2222222'], ['gtin', '05012345678900']],
            $this->codes($ledger, 'SK_2')
        );
    }

    public function test_with_no_national_codes_the_key_stays_with_its_own_reference(): void
    {
        $ledger = $this->week(IdentityLedger::new(), [
            $this->listing('100g', [self::GTIN, ['supplier_ref', 'AMPP-100g']]),
        ]);

        $ledger = $this->week($ledger, [
            $this->listing('100g', [['supplier_ref', 'AMPP-100g']]),
            $this->listing('30g', [self::GTIN, ['supplier_ref', 'AMPP-30g']]),
        ]);

        self::assertSame([['supplier_ref', 'AMPP-100g']], $this->codes($ledger, 'SK_1'));
    }

    public function test_the_outcome_does_not_depend_on_listing_order(): void
    {
        $before = $this->week(IdentityLedger::new(), [
            $this->listing('100g', [['cnk', '1111111'], self::GTIN]),
        ]);

        $after = [
            $this->listing('100g', [['cnk', '1111111']]),
            $this->listing('30g', [['cnk', '2222222'], self::GTIN]),
        ];

        $forward = $this->week($before, $after);
        $reversed = $this->week($before, array_reverse($after));

        self::assertSame([['cnk', '1111111']], $this->codes($forward, 'SK_1'));
        self::assertSame($this->allCodes($forward), $this->allCodes($reversed));
    }

    public function test_replacing_the_national_code_on_a_live_key_is_flagged(): void
    {
        $ledger = $this->week(IdentityLedger::new(), [
            $this->listing('r', [['cnk', '1111111'], self::GTIN]),
        ]);

        $events = $this->decide($ledger, [$this->listing('r', [['cnk', '2222222'], self::GTIN])]);

        self::assertTrue($this->hasSwapFlag($events), 'expected an identity_swap flag');
    }

    public function test_gaining_a_second_national_code_is_not_flagged(): void
    {
        $ledger = $this->week(IdentityLedger::new(), [
            $this->listing('r', [['cnk', '1111111'], self::GTIN]),
        ]);

        $events = $this->decide($ledger, [
            $this->listing('r', [['cnk', '1111111'], ['cnk', '2222222'], self::GTIN]),
        ]);

        self::assertFalse($this->hasSwapFlag($events));
    }

    // ── helpers ──────────────────────────────────────────────────────────────

    /** @param list<array{0: string, 1: string}> $codes */
    private function listing(string $ref, array $codes): Claim
    {
        return Substrate::claim('nhsbsa', 'identity', ['ref' => $ref, 'codes' => $codes], 'd1', 'd1');
    }

    /**
     * @param list<Claim> $claims
     *
     * @return list<\Ingot\DomainEvent>
     */
    private function decide(LedgerState $ledger, array $claims): array
    {
        $stamped = [];
        $i = 1;
        foreach ($claims as $claim) {
            $stamped[] = $claim->withOrder($i++);
        }

        return IdentityLedger::decide(
            $ledger,
            ['reconcile', Cluster::variants(Substrate::current($stamped)), 'd1']
        );
    }

    /** @param list<array<string,mixed>> $claims */
    private function week(LedgerState $ledger, array $claims): LedgerState
    {
        foreach ($this->decide($ledger, $claims) as $event) {
            $ledger = IdentityLedger::evolve($ledger, $event);
        }

        return $ledger;
    }

    /** @return list<array{0: string, 1: string}> */
    private function codes(LedgerState $ledger, string $key): array
    {
        $codes = array_values($ledger->members[$key] ?? []);
        sort($codes);

        return $codes;
    }

    /** @return array<string, list<array{0: string, 1: string}>> */
    private function allCodes(LedgerState $ledger): array
    {
        $out = [];
        foreach (array_keys($ledger->members) as $key) {
            $out[$key] = $this->codes($ledger, $key);
        }
        ksort($out);

        return $out;
    }

    /** @param list<\Ingot\DomainEvent> $events */
    private function hasSwapFlag(array $events): bool
    {
        foreach ($events as $event) {
            if ($event instanceof ConflictFlagged && ($event->subject[0] ?? null) === 'identity_swap') {
                return true;
            }
        }

        return false;
    }
}
