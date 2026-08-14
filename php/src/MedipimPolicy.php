<?php

declare(strict_types=1);

namespace Ingot;

/**
 * The CONCRETE medipim survivorship scoring policy (gr-7yw) — PHP-parity port of
 * lib/ingest/medipim_policy.ex. Builds the injected `(dimension, source): int` rank function
 * that {@see GoldenRecords::project()} and {@see Survivorship::decide()} accept as a policy;
 * the generic engine stays medipim-free.
 *
 * Reproduces SourcesRanker (gr-6y2 read-only audit):
 *
 *   - each FIELD carries a score map (sysId | orgId) => int; a source's score resolves by its
 *     sysId (org group) FIRST, then its orgId, else default 0
 *   - PENALTY: a non-system source NOT in the product's scoring org-set is devalued to −1. The
 *     scoring set is the product's organizations, ∪ labo orgs for region "be" ONLY, ∪ orgs
 *     introduced by the in-flight delta
 *   - highest score wins; equal scores break by legacy source-array order (DECISION, Ward
 *     2026-08-13: replicate the array-order pick for byte-parity)
 *
 * rank = -score * OFFSET + tieIndex — one integer, lower wins, mirroring the Elixir encoding so
 * both ports produce byte-identical decisions.
 */
final class MedipimPolicy
{
    private const OFFSET = 1_000_000;
    private const UNLISTED = self::OFFSET - 1;

    /**
     * @param array{
     *   region?: string,
     *   product_orgs?: list<string>,
     *   labo_orgs?: list<string>,
     *   delta_orgs?: list<string>,
     *   system_sources?: list<string>,
     *   field_scores?: array<string, array<string, int>>,
     *   sys_of?: array<string, string>,
     *   source_order?: list<string>,
     *   penalty?: bool
     * } $context
     */
    public static function rankFn(array $context): callable
    {
        $region = $context['region'] ?? 'be';
        $labo = $region === 'be' ? ($context['labo_orgs'] ?? []) : [];

        $scoringSet = array_fill_keys(
            array_merge($context['product_orgs'] ?? [], $labo, $context['delta_orgs'] ?? []),
            true
        );
        $systemSet = array_fill_keys($context['system_sources'] ?? [], true);
        $fieldScores = $context['field_scores'] ?? [];
        $sysOf = $context['sys_of'] ?? [];
        $tieOrder = array_flip($context['source_order'] ?? []);
        $penalty = $context['penalty'] ?? true;

        return static function (string $dimension, ?string $source) use (
            $scoringSet,
            $systemSet,
            $fieldScores,
            $sysOf,
            $tieOrder,
            $penalty
        ): int {
            $offProduct = !isset($systemSet[$source]) && !isset($scoringSet[$source]);

            if ($penalty && $offProduct) {
                $score = -1;
            } else {
                // sysId (org group) resolves BEFORE orgId; neither => default 0.
                $scores = $fieldScores[$dimension] ?? [];
                $sys = $source !== null ? ($sysOf[$source] ?? null) : null;
                $score = $sys !== null && isset($scores[$sys])
                    ? $scores[$sys]
                    : ($source !== null && isset($scores[$source]) ? $scores[$source] : 0);
            }

            $tie = $source !== null ? ($tieOrder[$source] ?? self::UNLISTED) : self::UNLISTED;

            return -$score * self::OFFSET + $tie;
        };
    }
}
