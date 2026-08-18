<?php

declare(strict_types=1);

namespace Ingot;

/**
 * The migration-validation diff view — ported from `MigrationDiff` (lib/ingest/migration_diff.ex).
 *
 * Reads LegacyXref's relation taxonomy and PublicId::collisions('cnk', log) and renders them as a
 * structured, JSON-safe report (findings + counts + needs_review). Pure fold — changes nothing.
 */
final class MigrationDiff
{
    /**
     * @param array{log: list<DomainEvent>} $rederivation
     * @return array{findings: list<array<string,mixed>>, counts: array<string,int>, needs_review: list<array<string,mixed>>}
     */
    public static function build(array $rederivation): array
    {
        $xref = LegacyXref::build($rederivation);

        return self::render($xref['legacy_to_key'], PublicId::collisions('cnk', $rederivation['log']));
    }

    /**
     * @param list<array<string,mixed>> $envelopes
     * @return array{findings: list<array<string,mixed>>, counts: array<string,int>, needs_review: list<array<string,mixed>>}
     */
    public static function fromEnvelopes(array $envelopes, mixed $at): array
    {
        return self::build(Rederivation::run($envelopes, $at));
    }

    /**
     * @param array<string, array<string,mixed>> $legacyToKey
     * @param list<array{code: array{0: string, 1: string}, keys: list<string>}> $collisions
     * @return array{findings: list<array<string,mixed>>, counts: array<string,int>, needs_review: list<array<string,mixed>>}
     */
    public static function render(array $legacyToKey, array $collisions): array
    {
        // Sort legacy findings by entity (the raw entity value).
        $entries = [];
        foreach ($legacyToKey as $entityKey => $placement) {
            $entries[] = [self::decodeEntity($entityKey), $placement];
        }
        usort($entries, static function (array $a, array $b): int {
            if (is_int($a[0]) && is_int($b[0])) {
                return $a[0] <=> $b[0];
            }

            return strcmp((string) $a[0], (string) $b[0]);
        });

        $legacyFindings = [];
        foreach ($entries as [$entity, $placement]) {
            $legacyFindings[] = self::legacyFinding($entity, $placement);
        }

        $findings = $legacyFindings;
        foreach ($collisions as $c) {
            $findings[] = self::collisionFinding($c);
        }

        $needsReview = [];
        foreach ($findings as $f) {
            if ($f['needs_review']) {
                $needsReview[] = $f;
            }
        }

        return ['findings' => $findings, 'counts' => self::counts($findings), 'needs_review' => $needsReview];
    }

    public static function toJson(array $report): string
    {
        return json_encode($report, JSON_UNESCAPED_SLASHES | JSON_UNESCAPED_UNICODE);
    }

    /**
     * @param mixed $entity
     * @param array<string,mixed> $placement
     * @return array<string,mixed>
     */
    private static function legacyFinding(mixed $entity, array $placement): array
    {
        $relation = $placement['relation'];

        if ($relation === 'stable') {
            return [
                'category' => 'confirmed', 'legacy_entity' => $entity, 'keys' => $placement['all'],
                'primary' => $placement['primary'], 'relation' => 'stable', 'evidence' => [],
                'confidence' => 'high', 'needs_review' => false,
            ];
        }
        if ($relation === 'split') {
            return [
                'category' => 'split', 'legacy_entity' => $entity, 'keys' => $placement['all'],
                'primary' => $placement['primary'], 'relation' => 'split',
                'evidence' => ['fragments' => $placement['all']],
                'confidence' => 'high', 'needs_review' => false,
            ];
        }
        // merged: ['merged', others] or ['merged', others, 'suspect']
        $others = $relation[1];
        $suspect = isset($relation[2]) && $relation[2] === 'suspect';
        if ($suspect) {
            return [
                'category' => 'merged', 'legacy_entity' => $entity, 'keys' => $placement['all'],
                'primary' => $placement['primary'], 'relation' => 'merged',
                'evidence' => ['merged_with' => $others, 'bridge' => 'barcode'],
                'confidence' => 'low', 'needs_review' => true,
            ];
        }

        return [
            'category' => 'merged', 'legacy_entity' => $entity, 'keys' => $placement['all'],
            'primary' => $placement['primary'], 'relation' => 'merged',
            'evidence' => ['merged_with' => $others],
            'confidence' => 'high', 'needs_review' => false,
        ];
    }

    /**
     * @param array{code: array{0: string, 1: string}, keys: list<string>} $collision
     * @return array<string,mixed>
     */
    private static function collisionFinding(array $collision): array
    {
        return [
            'category' => 'collision', 'code' => self::renderCode($collision['code']),
            'keys' => $collision['keys'], 'relation' => 'collision',
            'evidence' => ['collided_keys' => $collision['keys']],
            'confidence' => 'low', 'needs_review' => true,
        ];
    }

    /** @param array{0: string, 1: string} $code */
    private static function renderCode(array $code): string
    {
        return $code[0].':'.$code[1];
    }

    /**
     * @param list<array<string,mixed>> $findings
     * @return array<string,int>
     */
    private static function counts(array $findings): array
    {
        $c = ['confirmed' => 0, 'merged' => 0, 'split' => 0, 'collision' => 0, 'needs_review' => 0];
        foreach ($findings as $f) {
            ++$c[$f['category']];
            if ($f['needs_review']) {
                ++$c['needs_review'];
            }
        }

        return $c;
    }

    private static function decodeEntity(string $part): mixed
    {
        if (str_starts_with($part, 'i:')) {
            return (int) substr($part, 2);
        }

        return substr($part, 2);
    }
}
