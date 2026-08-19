<?php

declare(strict_types=1);

namespace Ingot\Tests;

use Ingot\IdentityScheme;
use Ingot\Lane;
use Ingot\Lanes;
use PHPUnit\Framework\TestCase;

final class LaneIdentitySchemeTest extends TestCase
{
    public function test_lane_cases_match_lanes_list(): void
    {
        self::assertSame(
            array_map(static fn (Lane $lane): string => $lane->value, Lane::cases()),
            Lanes::lanes(),
        );
    }

    public function test_lane_prefixes(): void
    {
        self::assertSame('SK', Lane::Product->prefix());
        self::assertSame('SUB', Lane::Substance->prefix());
        self::assertSame('DSC', Lane::Description->prefix());
        self::assertSame('MED', Lane::Media->prefix());
        self::assertSame('DSC', Lanes::prefix('description'));
    }

    public function test_identity_scheme_for_lane(): void
    {
        self::assertSame(IdentityScheme::ProductId, Lane::Product->identityScheme());
        self::assertSame(IdentityScheme::TextId, Lane::Description->identityScheme());
        self::assertSame(IdentityScheme::AssetId, Lane::Media->identityScheme());
        self::assertNull(Lane::Substance->identityScheme());
        self::assertSame(IdentityScheme::TextId, IdentityScheme::forLane(Lane::Description));
    }

    public function test_identity_scheme_lane_round_trip(): void
    {
        self::assertSame(Lane::Product, IdentityScheme::ProductId->lane());
        self::assertSame(Lane::Description, IdentityScheme::TextId->lane());
        self::assertSame(Lane::Media, IdentityScheme::AssetId->lane());
        self::assertSame(Lane::Media, IdentityScheme::LeafletId->lane());
    }

    public function test_lanes_of_scheme_uses_identity_scheme_enum(): void
    {
        self::assertSame(Lane::Description, Lanes::ofScheme('text_id'));
        self::assertSame(Lane::Media, Lanes::ofScheme('asset_id'));
        self::assertSame(Lane::Media, Lanes::ofScheme('leaflet_id'));
        self::assertSame(Lane::Product, Lanes::ofScheme('product_id'));
        self::assertSame(Lane::Product, Lanes::ofScheme('cnk'));
        self::assertNull(Lanes::ofScheme('uuid'));
    }

    public function test_coerce_accepts_enum_or_string(): void
    {
        self::assertSame(IdentityScheme::AssetId, IdentityScheme::coerce(IdentityScheme::AssetId));
        self::assertSame(IdentityScheme::AssetId, IdentityScheme::coerce('asset_id'));
    }
}
