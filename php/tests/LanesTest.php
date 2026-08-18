<?php

declare(strict_types=1);

namespace Ingot\Tests;

use Ingot\Lanes;
use PHPUnit\Framework\TestCase;

/**
 * Ported from entity_lanes_test.exs / golden_record_test.exs (lane routing): scheme → lane,
 * key → lane, claim lane resolution including the explicit-entity fallback and mixed-lane error.
 */
final class LanesTest extends TestCase
{
    public function test_lane_of_scheme(): void
    {
        self::assertSame('product', Lanes::laneOfScheme('cnk'));
        self::assertSame('product', Lanes::laneOfScheme('gtin'));
        self::assertSame('substance', Lanes::laneOfScheme('cas'));
        self::assertSame('description', Lanes::laneOfScheme('text_id'));
        self::assertSame('media', Lanes::laneOfScheme('asset_id'));
        self::assertNull(Lanes::laneOfScheme('uuid'));
    }

    public function test_lane_of_key_by_prefix(): void
    {
        self::assertSame('product', Lanes::laneOfKey('SK_1'));
        self::assertSame('substance', Lanes::laneOfKey('SUB_3'));
        self::assertSame('description', Lanes::laneOfKey('DSC_12'));
        self::assertSame('media', Lanes::laneOfKey('MED_2'));
    }

    public function test_of_claim_unique_lane_explicit_entity_and_mixed(): void
    {
        $idClaim = fn (array $codes, array $extra = []) => new \Ingot\Claim(
            null,
            'identity',
            ['codes' => $codes] + $extra,
            1,
            1,
        );

        self::assertSame(['ok', 'product'], Lanes::ofClaim($idClaim([['cnk', '111']])));
        self::assertSame(['ok', 'substance'], Lanes::ofClaim($idClaim([['cas', '50-00-0']])));
        // all-neutral codes need an explicit entity
        self::assertSame(['ok', 'media'], Lanes::ofClaim($idClaim([['uuid', 'x']], ['entity' => 'media'])));
        self::assertSame(['ok', 'product'], Lanes::ofClaim($idClaim([['uuid', 'x']])));
        // two lanes in one claim is a contract violation
        self::assertSame(['error', ['mixed_lanes', ['product', 'substance']]], Lanes::ofClaim($idClaim([['cnk', '1'], ['cas', '2']])));
    }

    public function test_partition_members_by_lane(): void
    {
        $members = [
            'SK_1' => [],
            'MED_1' => [],
            'DSC_1' => [],
        ];
        $parts = Lanes::partitionMembers($members);
        self::assertSame(['SK_1'], array_keys($parts['product']));
        self::assertSame(['MED_1'], array_keys($parts['media']));
        self::assertSame(['DSC_1'], array_keys($parts['description']));
        self::assertSame([], $parts['substance']);
    }
}
