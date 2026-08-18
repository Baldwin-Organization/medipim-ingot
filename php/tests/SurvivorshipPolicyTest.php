<?php

declare(strict_types=1);

namespace Ingot\Tests;

use Ingot\Priority;
use Ingot\Survivorship;
use PHPUnit\Framework\TestCase;

/**
 * PHP-parity mirror of test/survivorship_policy_test.exs (gr-6y2): Survivorship is policy-driven.
 * A Priority ranks by tier (back-compat); an injected callable carries context-aware scoring
 * (medipim's off-product penalty) without touching the core. Attribute rankings are always applied.
 */
final class SurvivorshipPolicyTest extends TestCase
{
    /** @param mixed $value */
    private static function e(?string $source, $value, int $order): array
    {
        return ['source' => $source, 'value' => $value, 'order' => $order];
    }

    public function test_backcompat_priority_ranks_by_tier(): void
    {
        $priority = Priority::new(['name' => [['orgA'], ['orgB']]], []);
        $d = Survivorship::decide('name', [self::e('orgA', 'Foo', 1), self::e('orgB', 'Bar', 2)], $priority);

        self::assertSame('orgA', $d->winner);
        self::assertSame('Foo', $d->value);
        self::assertSame('resolved', $d->status);
    }

    public function test_injected_rank_fn_expresses_off_product_penalty(): void
    {
        $scores = ['name' => ['A' => 10, 'B' => 5]];

        // rank fn closes over the product's scoring org-set; an off-product source is devalued to -1.
        $rank = static function (array $scoringOrgs) use ($scores): callable {
            return static function (string $dim, ?string $src) use ($scores, $scoringOrgs): int {
                $base = $scores[$dim][$src] ?? 0;
                $score = in_array($src, $scoringOrgs, true) ? $base : -1;

                return -$score; // higher score => lower (better) rank
            };
        };

        $entries = [self::e('B', 'keep', 1), self::e('X', 'drop', 2)];

        // P1: X off-product -> penalised below B -> B wins.
        self::assertSame('B', Survivorship::decide('name', $entries, $rank(['A', 'B']))->winner);

        // P2: X on-product -> B penalised -> X wins. Same claims, different context, different winner.
        self::assertSame('X', Survivorship::decide('name', $entries, $rank(['X']))->winner);
    }

    public function test_equal_rank_disagreement_has_no_made_up_winner_and_is_order_independent(): void
    {
        $policy = Priority::new([], []);
        $entries = [
            self::e('source-b', 'Beta', 2),
            self::e('source-a', 'Alpha', 1),
            self::e('source-c', 'Gamma', 3),
        ];

        $expected = [
            'value' => null,
            'winner' => null,
            'status' => 'needs_review',
            'candidates' => [
                ['source-a', 'Alpha'],
                ['source-b', 'Beta'],
                ['source-c', 'Gamma'],
            ],
        ];

        self::assertSame($expected, Survivorship::decide('name', $entries, $policy)->toArray());
        self::assertSame($expected, Survivorship::decide('name', array_reverse($entries), $policy)->toArray());
    }

    public function test_equal_rank_sources_that_agree_still_resolve(): void
    {
        $decision = Survivorship::decide(
            'name',
            [self::e('source-b', 'Same', 2), self::e('source-a', 'Same', 1)],
            Priority::new([], [])
        );

        self::assertSame('Same', $decision->value);
        self::assertSame('source-a', $decision->winner);
        self::assertSame('resolved', $decision->status);
    }
}
