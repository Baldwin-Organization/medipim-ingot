<?php

declare(strict_types=1);

namespace Ingot\Tests;

use Ingot\Claim;
use Ingot\Cluster;
use Ingot\Sets;
use Ingot\Substrate;
use PHPUnit\Framework\TestCase;

/**
 * Pins the connected-components clustering: shared codes bridge nothing; equivalent GTIN widths
 * merge; clusters come out sorted by their minimum code.
 */
final class ClusterTest extends TestCase
{
    private function idClaim(string $ref, array $codes): Claim
    {
        return Substrate::claim('s', 'identity', ['ref' => $ref, 'codes' => $codes], 1, 1);
    }

    public function test_shared_code_bridges_nothing(): void
    {
        $claims = [
            $this->idClaim('A', [['gtin', '7777'], ['gtin', '1000']]),
            $this->idClaim('B', [['gtin', '7777'], ['gtin', '2000']]),
        ];

        $without = Cluster::variants(Substrate::current($claims));
        self::assertCount(1, $without, 'without the share, 7777 bridges them');

        $shared = Sets::of([['gtin', '7777']]);
        $with = Cluster::variants(Substrate::current($claims), $shared);
        self::assertCount(2, $with);
    }

    public function test_equivalent_gtin_widths_merge(): void
    {
        $claims = [
            $this->idClaim('A', [['ean', '5012345678900']]),
            $this->idClaim('B', [['gtin', '05012345678900']]),
        ];
        $clusters = Cluster::variants(Substrate::current($claims));
        self::assertCount(1, $clusters);
        self::assertTrue(Sets::member($clusters[0], ['gtin', '05012345678900']));
    }

    public function test_clusters_sorted_by_minimum_code(): void
    {
        $claims = [
            $this->idClaim('B', [['gtin', '0999']]),
            $this->idClaim('A', [['cnk', '0001']]),
        ];
        $clusters = Cluster::variants(Substrate::current($claims));
        self::assertCount(2, $clusters);
        // the cnk:0001 cluster sorts first (cnk < gtin)
        self::assertTrue(Sets::member($clusters[0], ['cnk', '0001']));
    }
}
