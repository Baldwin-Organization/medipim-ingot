<?php

declare(strict_types=1);

namespace Ingot\Tests;

use Ingot\CanonicalClaims;
use PHPUnit\Framework\TestCase;

/**
 * Ported from test/contract/canonical_claims_test.exs: the "scheme:value" codec and the trusted
 * backfill seam (member_of lowers to an edge; unix-second temporals pass through).
 */
final class CanonicalClaimsTest extends TestCase
{
    public function test_parse_code_folds_names_splits_on_first_colon(): void
    {
        self::assertSame(['ok', ['cnk', '1000001']], CanonicalClaims::parseCode('cnk:1000001'));
        self::assertSame(['ok', ['mpn', 'AB:12']], CanonicalClaims::parseCode('mpn:AB:12'));
        self::assertSame('error', CanonicalClaims::parseCode('no-colon')[0]);
        self::assertSame('error', CanonicalClaims::parseCode(':empty-scheme')[0]);
    }

    public function test_code_string_is_parse_code_inverse(): void
    {
        foreach ([['cnk', '1000001'], ['gtin', '05012345678900'], ['mysteryScheme', 'XYZ']] as $code) {
            self::assertSame(['ok', $code], CanonicalClaims::parseCode(CanonicalClaims::codeString($code)));
        }
    }

    public function test_backfill_member_of_lowers_to_edge_with_unix_temporals(): void
    {
        $batch = [[
            'kind' => 'member_of', 'source' => '44', 'code' => 'cnk:3612173',
            'collection' => 'brands', 'member' => '211',
            'valid_from' => 1535726805, 'recorded_at' => 1535726805,
        ]];

        $claims = CanonicalClaims::toEngineBang($batch);
        self::assertCount(1, $claims);
        $claim = $claims[0];
        self::assertSame('edge', $claim->kind);
        self::assertSame(['from' => ['cnk', '3612173'], 'relation' => 'member_of', 'to' => ['brands', '211']], $claim->data);
        self::assertSame(1535726805, $claim->validFrom);
        self::assertSame(1535726805, $claim->recordedAt);
    }

    public function test_identity_codes_canonicalize(): void
    {
        $batch = [[
            'kind' => 'identity', 'source' => 'medipim', 'ref' => 'P-1',
            'codes' => ['cnk:1000001', 'ean:5012345678900'],
            'recorded_at' => 100,
        ]];
        $claim = CanonicalClaims::toEngineBang($batch)[0];
        self::assertSame(['ref' => 'P-1', 'codes' => [['cnk', '1000001'], ['gtin', '05012345678900']]], $claim->data);
    }
}
