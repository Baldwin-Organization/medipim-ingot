<?php

declare(strict_types=1);

namespace Ingot;

/**
 * The durable legacy → new cross-reference — ported from `LegacyXref` (lib/ingest/legacy_xref.ex).
 *
 * Reads the grouping claims back out and joins them against the re-derived surrogate keys to answer:
 * where did each legacy entity land, and did it stay put (stable), get absorbed (merged), or
 * fragment (split)? The over-merge guard tags a barcode-only bridge as :suspect.
 */
final class LegacyXref
{
    /**
     * @param array{log: list<DomainEvent>, ledger: LedgerState} $rederivation
     * @return array{key_to_legacy: array<string, list<mixed>>, legacy_to_key: array<string, array<string,mixed>>}
     */
    public static function build(array $rederivation): array
    {
        $log = $rederivation['log'];
        $ledger = $rederivation['ledger'];
        $groupings = self::groupings($log);

        // entity => code-set of its grouping codes.
        $entityCodes = [];
        foreach ($groupings as $g) {
            $e = self::entityKey($g->data['product']);
            if (!isset($entityCodes[$e])) {
                $entityCodes[$e] = ['value' => $g->data['product'], 'codes' => []];
            }
            $entityCodes[$e]['codes'][Codes::key($g->data['code'])] = $g->data['code'];
        }

        // SK => {entities, sources, codes} — product lane only.
        $perKey = [];
        foreach (Lanes::partitionMembers($ledger->members)['product'] as $key => $memberCodes) {
            $contributing = [];
            foreach ($groupings as $g) {
                if (Sets::member($memberCodes, $g->data['code'])) {
                    $contributing[] = $g;
                }
            }
            $entities = [];
            $entSeen = [];
            $sources = [];
            foreach ($contributing as $g) {
                $ek = self::entityKey($g->data['product']);
                if (!isset($entSeen[$ek])) {
                    $entSeen[$ek] = true;
                    $entities[] = $g->data['product'];
                }
                $sources[$g->source] = true;
            }
            usort($entities, self::compareEntities(...));
            $perKey[$key] = ['entities' => $entities, 'sources' => $sources, 'codes' => $memberCodes];
        }

        $keyToLegacy = [];
        foreach ($perKey as $key => $info) {
            $keyToLegacy[$key] = $info['entities'];
        }

        $legacyToKey = self::invert($keyToLegacy, $perKey, $entityCodes);

        return ['key_to_legacy' => $keyToLegacy, 'legacy_to_key' => $legacyToKey];
    }

    /**
     * @param list<array<string,mixed>> $envelopes
     * @return array{key_to_legacy: array<string, list<mixed>>, legacy_to_key: array<string, array<string,mixed>>}
     */
    public static function fromEnvelopes(array $envelopes, mixed $at): array
    {
        return self::build(Rederivation::run($envelopes, $at));
    }

    /**
     * @param list<DomainEvent> $log
     * @return list<Claim>
     */
    private static function groupings(array $log): array
    {
        $out = [];
        foreach ($log as $e) {
            if ($e instanceof Claim && $e->kind === 'grouping') {
                $out[] = $e;
            }
        }

        return $out;
    }

    /**
     * @param array<string, list<mixed>> $keyToLegacy
     * @param array<string, array<string,mixed>> $perKey
     * @param array<string, array{value: mixed, codes: array<string, array{0: string, 1: string}>}> $entityCodes
     * @return array<string, array<string,mixed>>
     */
    private static function invert(array $keyToLegacy, array $perKey, array $entityCodes): array
    {
        // entity => list of keys.
        $entityToKeys = [];
        $entityValue = [];
        foreach ($keyToLegacy as $key => $entities) {
            foreach ($entities as $e) {
                $ek = self::entityKey($e);
                $entityToKeys[$ek][] = $key;
                $entityValue[$ek] = $e;
            }
        }

        $out = [];
        foreach ($entityToKeys as $ek => $keys) {
            $all = array_values(array_unique($keys));
            usort($all, static fn (string $a, string $b): int => self::keyNum($a) <=> self::keyNum($b));

            $out[(string) $ek] = [
                'primary' => self::primary($all, $perKey),
                'all' => $all,
                'relation' => self::relation($all, $entityValue[$ek], $keyToLegacy, $entityCodes),
            ];
        }

        return $out;
    }

    /**
     * @param list<string> $all
     * @param mixed $entity
     * @param array<string, list<mixed>> $keyToLegacy
     * @param array<string, array{value: mixed, codes: array<string, array{0: string, 1: string}>}> $entityCodes
     * @return string|array{0: string, 1: mixed}|array{0: string, 1: mixed, 2: string}
     */
    private static function relation(array $all, mixed $entity, array $keyToLegacy, array $entityCodes): string|array
    {
        if (count($all) !== 1) {
            return 'split';
        }
        $key = $all[0];

        $others = [];
        foreach ($keyToLegacy[$key] as $co) {
            if (self::entityKey($co) !== self::entityKey($entity)) {
                $others[] = $co;
            }
        }
        usort($others, self::compareEntities(...));

        if ($others === []) {
            return 'stable';
        }

        return self::merged($entity, $others, $entityCodes);
    }

    /**
     * @param mixed $entity
     * @param list<mixed> $others
     * @param array<string, array{value: mixed, codes: array<string, array{0: string, 1: string}>}> $entityCodes
     * @return array{0: string, 1: list<mixed>}|array{0: string, 1: list<mixed>, 2: string}
     */
    private static function merged(mixed $entity, array $others, array $entityCodes): array
    {
        $mine = $entityCodes[self::entityKey($entity)]['codes'] ?? [];

        $bridge = [];
        foreach ($others as $other) {
            $theirs = $entityCodes[self::entityKey($other)]['codes'] ?? [];
            $bridge = Sets::union($bridge, Sets::intersection($mine, $theirs));
        }

        foreach (Sets::values($bridge) as $code) {
            if (CodeRegistry::nationalGrade($code[0])) {
                return ['merged', $others];
            }
        }

        return ['merged', $others, 'suspect'];
    }

    /**
     * @param list<string> $all
     * @param array<string, array<string,mixed>> $perKey
     */
    private static function primary(array $all, array $perKey): string
    {
        if (count($all) === 1) {
            return $all[0];
        }

        $best = $all[0];
        $bestScore = self::primaryScore($all[0], $perKey);
        foreach ($all as $key) {
            $score = self::primaryScore($key, $perKey);
            if ($score > $bestScore) {
                $bestScore = $score;
                $best = $key;
            }
        }

        return $best;
    }

    /**
     * @param array<string, array<string,mixed>> $perKey
     * @return array{0: int, 1: int, 2: int}
     */
    private static function primaryScore(string $key, array $perKey): array
    {
        $info = $perKey[$key];

        return [self::spineRank($info['codes']), count($info['sources']), -self::keyNum($key)];
    }

    /** @param array<string, array{0: string, 1: string}> $codes */
    private static function spineRank(array $codes): int
    {
        foreach (Sets::values($codes) as $c) {
            if ($c[0] === 'cnk') {
                return 2;
            }
        }
        foreach (Sets::values($codes) as $c) {
            if ($c[0] === 'gtin') {
                return 1;
            }
        }

        return 0;
    }

    private static function keyNum(string $key): int
    {
        return (int) substr($key, strrpos($key, '_') + 1);
    }

    private static function entityKey(mixed $entity): string
    {
        return (is_int($entity) ? 'i:' : 's:').$entity;
    }

    private static function compareEntities(mixed $a, mixed $b): int
    {
        if (is_int($a) && is_int($b)) {
            return $a <=> $b;
        }

        return strcmp((string) $a, (string) $b);
    }
}
