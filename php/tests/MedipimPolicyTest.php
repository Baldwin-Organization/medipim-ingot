<?php

declare(strict_types=1);

namespace Ingot\Tests;

use Ingot\MedipimPolicy;
use Ingot\Survivorship;
use PHPUnit\Framework\TestCase;

/**
 * PHP-parity mirror of test/ingest/medipim_policy_test.exs (gr-7yw): the concrete medipim
 * scoring policy reproduces SourcesRanker through the generic Survivorship seam.
 */
final class MedipimPolicyTest extends TestCase
{
    /** @param list<array{0: string, 1: mixed}> $pairs */
    private static function entries(array $pairs): array
    {
        $entries = [];
        foreach ($pairs as $i => [$source, $value]) {
            $entries[] = ['source' => $source, 'value' => $value, 'order' => $i + 1];
        }

        return $entries;
    }

    private static function decide(array $entries, array $context, string $field = 'name'): \Ingot\Decision
    {
        return Survivorship::decide($field, $entries, MedipimPolicy::rankFn($context));
    }

    public function testHigherScoredOrgWinsTheField(): void
    {
        $decision = self::decide(
            self::entries([['orgA', 'Foo'], ['orgB', 'Bar']]),
            ['product_orgs' => ['orgA', 'orgB'], 'field_scores' => ['name' => ['orgA' => 10, 'orgB' => 5]]]
        );

        self::assertSame('Foo', $decision->value);
        self::assertSame('orgA', $decision->winner);
        self::assertSame('resolved', $decision->status);
    }

    public function testSysIdResolvesBeforeOrgId(): void
    {
        $decision = self::decide(
            self::entries([['orgA', 'Foo'], ['orgB', 'Bar']]),
            [
                'product_orgs' => ['orgA', 'orgB'],
                'sys_of' => ['orgA' => 'sysX'],
                'field_scores' => ['name' => ['sysX' => 20, 'orgA' => 1, 'orgB' => 10]],
            ]
        );

        self::assertSame('orgA', $decision->winner);
    }

    public function testOffProductNonSystemSourceIsDevaluedToMinusOne(): void
    {
        // orgOff scores 10 in the table but is not on the product: the default-0 orgB wins.
        $decision = self::decide(
            self::entries([['orgOff', 'Foo'], ['orgB', 'Bar']]),
            ['product_orgs' => ['orgB'], 'field_scores' => ['name' => ['orgOff' => 10]]]
        );

        self::assertSame('orgB', $decision->winner);
        self::assertSame('resolved', $decision->status);
    }

    public function testSystemSourceIsNeverPenalized(): void
    {
        $decision = self::decide(
            self::entries([['sys1', 'Foo'], ['orgB', 'Bar']]),
            [
                'product_orgs' => ['orgB'],
                'system_sources' => ['sys1'],
                'field_scores' => ['name' => ['sys1' => 10]],
            ]
        );

        self::assertSame('sys1', $decision->winner);
    }

    public function testLaboOrgsJoinTheScoringSetForRegionBeOnly(): void
    {
        $entries = self::entries([['labo1', 'Foo'], ['orgB', 'Bar']]);
        $base = ['product_orgs' => [], 'labo_orgs' => ['labo1'], 'source_order' => ['labo1', 'orgB']];

        self::assertSame('labo1', self::decide($entries, $base + ['region' => 'be'])->winner);

        $fr = ['region' => 'fr', 'product_orgs' => ['orgB']] + $base;
        self::assertSame('orgB', self::decide($entries, $fr)->winner);
    }

    public function testDeltaOrgsStillRank(): void
    {
        $decision = self::decide(
            self::entries([['orgNew', 'Foo'], ['orgB', 'Bar']]),
            [
                'product_orgs' => ['orgB'],
                'delta_orgs' => ['orgNew'],
                'field_scores' => ['name' => ['orgNew' => 5]],
            ]
        );

        self::assertSame('orgNew', $decision->winner);
    }

    public function testEqualScoresResolveByArrayOrderNeverNeedsReview(): void
    {
        $decision = self::decide(
            self::entries([['orgA', 'Foo'], ['orgB', 'Bar']]),
            ['product_orgs' => ['orgA', 'orgB'], 'source_order' => ['orgB', 'orgA']]
        );

        self::assertSame('Bar', $decision->value);
        self::assertSame('orgB', $decision->winner);
        self::assertSame('resolved', $decision->status);
    }

    public function testUnlistedEqualScoreSourcesStayNeedsReview(): void
    {
        $decision = self::decide(
            self::entries([['orgA', 'Foo'], ['orgB', 'Bar']]),
            ['product_orgs' => ['orgA', 'orgB']]
        );

        self::assertSame('needs_review', $decision->status);
    }

    public function testPenaltyToggleFlipsTheWinner(): void
    {
        $entries = self::entries([['orgOff', 'Foo'], ['orgA', 'Bar']]);
        $context = [
            'product_orgs' => ['orgA'],
            'field_scores' => ['name' => ['orgOff' => 10]],
            'source_order' => ['orgA', 'orgOff'],
        ];

        self::assertSame('orgA', self::decide($entries, $context)->winner);
        self::assertSame('orgOff', self::decide($entries, ['penalty' => false] + $context)->winner);
    }
}
