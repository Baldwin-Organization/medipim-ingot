<?php

declare(strict_types=1);

namespace Ingot\Tests;

use Ingot\Substrate;
use PHPUnit\Framework\TestCase;

/**
 * Pins Substrate's claim construction: identity codes canonicalize, member_of lowers to an edge,
 * and current/1 keeps the latest claim per slot.
 */
final class SubstrateTest extends TestCase
{
    public function test_identity_codes_canonicalize(): void
    {
        $claim = Substrate::claim('s', 'identity', ['ref' => 'A', 'codes' => [['ean', '5012345678900']]], 1, 1);
        self::assertSame([['gtin', '05012345678900']], $claim->data['codes']);
    }

    public function test_member_of_lowers_to_edge(): void
    {
        $claim = Substrate::claim('who', 'member_of', ['member_code' => ['gtin', '0111'], 'collection' => ['atc', 'A10']], 1, 1);
        self::assertSame('edge', $claim->kind);
        self::assertSame('member_of', $claim->data['relation']);
        self::assertSame(['gtin', '0111'], $claim->data['from']);
        self::assertSame(['atc', 'A10'], $claim->data['to']);
    }

    public function test_current_keeps_latest_per_slot(): void
    {
        $c1 = Substrate::claim('s', 'attribute', ['code' => ['gtin', '0111'], 'field' => 'name', 'value' => 'old'], 1, 1)->withOrder(1);
        $c2 = Substrate::claim('s', 'attribute', ['code' => ['gtin', '0111'], 'field' => 'name', 'value' => 'new'], 1, 1)->withOrder(2);

        $current = Substrate::current([$c1, $c2]);
        self::assertCount(1, $current);
        self::assertSame('new', $current[0]->data['value']);
    }

    public function test_edge_member_value_trims(): void
    {
        // a tab-only member trims to "" via Codes::canonicalize on the edge endpoint
        $claim = Substrate::claim('s', 'edge', ['from' => ['cnk', '1'], 'relation' => 'member_of', 'to' => ['brands', "\t"]], 1, 1);
        self::assertSame(['brands', ''], $claim->data['to']);
    }
}
