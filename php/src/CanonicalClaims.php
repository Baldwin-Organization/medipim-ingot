<?php

declare(strict_types=1);

namespace Ingot;

/**
 * Canonical claims (the wire shape) → engine claims — ported from `CanonicalClaims`
 * (lib/contract/canonical_claims.ex). The generic, source-agnostic half of the ingest split.
 *
 * Only the trusted/backfill entrypoint `toEngineBang` is ported (the 422156 fold path uses it via
 * ClaimMapping); the live-wire `to_engine/2` validator is out of scope. Codes are "scheme:value"
 * strings — `parseCode`/`codeString` are the two directions.
 */
final class CanonicalClaims
{
    /**
     * Translate WITHOUT validating (the trusted/backfill entrypoint). `$recordedAt` overrides each
     * claim's own recorded_at when supplied (the live path's server clock).
     *
     * @param list<array<string,mixed>> $claims wire-shaped claim maps
     * @return list<Claim> engine claims
     */
    public static function toEngineBang(array $claims, mixed $recordedAt = null): array
    {
        $out = [];
        foreach ($claims as $m) {
            $out[] = self::build($m, $recordedAt);
        }

        return $out;
    }

    /**
     * @param array<string,mixed> $m
     */
    private static function build(array $m, mixed $at): Claim
    {
        return match ($m['kind']) {
            'identity' => self::buildIdentity($m, $at),
            'edge' => self::buildEdge($m, $at),
            'attribute' => self::buildAttribute($m, $at),
            'media' => self::buildMedia($m, $at),
            'grouping' => self::buildGrouping($m, $at),
            'member_of' => self::buildMemberOf($m, $at),
            default => throw new \InvalidArgumentException('malformed claim kind: '.($m['kind'] ?? '?')),
        };
    }

    /**
     * @param array<string,mixed> $m
     */
    private static function buildIdentity(array $m, mixed $at): Claim
    {
        $codes = array_map(self::codeBang(...), $m['codes']);
        $data = ['ref' => $m['ref'], 'codes' => $codes];
        if (isset($m['entity'])) {
            $lane = Lanes::parse($m['entity']);
            if ($lane === null) {
                throw new \InvalidArgumentException('unknown entity lane: '.$m['entity']);
            }
            $data['entity'] = $lane;
        }

        return Substrate::claim($m['source'], 'identity', $data, self::validFrom($m, $at), self::recordedAt($m, $at), $m['valid_to'] ?? null, $m['by'] ?? null);
    }

    /**
     * @param array<string,mixed> $m
     */
    private static function buildEdge(array $m, mixed $at): Claim
    {
        $relation = Relations::parse($m['relation']);
        if ($relation === null) {
            throw new \InvalidArgumentException('unknown relation: '.$m['relation']);
        }
        $data = ['from' => self::codeBang($m['from']), 'relation' => $relation, 'to' => self::codeBang($m['to'])];

        return Substrate::claim($m['source'], 'edge', $data, self::validFrom($m, $at), self::recordedAt($m, $at), $m['valid_to'] ?? null, $m['by'] ?? null);
    }

    /**
     * @param array<string,mixed> $m
     */
    private static function buildAttribute(array $m, mixed $at): Claim
    {
        $data = ['code' => self::codeBang($m['code']), 'field' => $m['field'], 'value' => $m['value']];

        return Substrate::claim($m['source'], 'attribute', $data, self::validFrom($m, $at), self::recordedAt($m, $at), $m['valid_to'] ?? null, $m['by'] ?? null);
    }

    /**
     * @param array<string,mixed> $m
     */
    private static function buildMedia(array $m, mixed $at): Claim
    {
        $role = ($m['role'] ?? null) === 'primary' ? 'primary' : 'secondary';
        $data = ['asset' => ['dam', $m['asset']], 'target' => self::codeBang($m['target']), 'role' => $role, 'uri' => $m['uri']];

        return Substrate::claim($m['source'], 'media', $data, self::validFrom($m, $at), self::recordedAt($m, $at), $m['valid_to'] ?? null, $m['by'] ?? null);
    }

    /**
     * @param array<string,mixed> $m
     */
    private static function buildGrouping(array $m, mixed $at): Claim
    {
        $data = ['code' => self::codeBang($m['code']), 'product' => $m['product']];

        return Substrate::claim($m['source'], 'grouping', $data, self::validFrom($m, $at), self::recordedAt($m, $at), $m['valid_to'] ?? null, $m['by'] ?? null);
    }

    /**
     * @param array<string,mixed> $m
     */
    private static function buildMemberOf(array $m, mixed $at): Claim
    {
        $data = ['member_code' => self::codeBang($m['code']), 'collection' => [$m['collection'], $m['member']]];

        return Substrate::claim($m['source'], 'member_of', $data, self::validFrom($m, $at), self::recordedAt($m, $at), $m['valid_to'] ?? null, $m['by'] ?? null);
    }

    /**
     * Parse one "scheme:value" string into an engine [scheme, value] code, splitting on the FIRST
     * colon. Returns ['ok', code] or ['error', message].
     *
     * @return array{0: string, 1: mixed}
     */
    public static function parseCode(mixed $raw): array
    {
        if (!is_string($raw)) {
            return ['error', 'code must be a "scheme:value" string'];
        }
        $parts = explode(':', $raw, 2);
        if (count($parts) !== 2 || $parts[0] === '' || $parts[1] === '') {
            return ['error', 'code must be "scheme:value"'];
        }

        return ['ok', [CodeRegistry::engineScheme($parts[0]), $parts[1]]];
    }

    /**
     * Format an engine [scheme, value] code as a "scheme:value" wire string.
     *
     * @param array{0: string, 1: string} $code
     */
    public static function codeString(array $code): string
    {
        return $code[0].':'.$code[1];
    }

    /**
     * @return array{0: string, 1: string}
     */
    private static function codeBang(string $raw): array
    {
        $result = self::parseCode($raw);
        if ($result[0] !== 'ok') {
            throw new \InvalidArgumentException('malformed code: '.$raw);
        }

        return $result[1];
    }

    /** @param array<string,mixed> $m */
    private static function recordedAt(array $m, mixed $at): mixed
    {
        if ($at !== null) {
            return $at;
        }
        if (!array_key_exists('recorded_at', $m)) {
            throw new \InvalidArgumentException('claim missing recorded_at');
        }

        return $m['recorded_at'];
    }

    /** @param array<string,mixed> $m */
    private static function validFrom(array $m, mixed $at): mixed
    {
        // Passes ISO date strings (live wire) and ints alike — only null/absent falls through.
        if (array_key_exists('valid_from', $m) && $m['valid_from'] !== null) {
            return $m['valid_from'];
        }

        return self::recordedAt($m, $at);
    }
}
