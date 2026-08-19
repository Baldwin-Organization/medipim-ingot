<?php

declare(strict_types=1);

namespace Ingot;

/**
 * Typed entity lanes — ported from `Lanes` in lib/golden_record_core.ex.
 *
 * Every code scheme belongs to exactly one entity type; identity claims route to their lane and
 * each lane folds its own ledger under a lane-qualified surrogate-key prefix. `uuid` is the one
 * shared (lane-neutral) scheme, so a claim made of only lane-neutral codes must carry an explicit
 * `entity`. Cross-lane bridging is structurally impossible — the lanes are disjoint folds.
 *
 * Prefer the {@see Lane} / {@see IdentityScheme} enums at call sites; the string helpers here remain
 * for the engine's internal wire shapes and for backward compatibility.
 */
final class Lanes
{
    /** @var list<string> */
    public const LANES = ['product', 'substance', 'description', 'media'];

    /** Non-product scheme => lane. Anything unlisted is 'product' (every pre-lane scheme was a product code). */
    private const LANE_OF = [
        'cas' => 'substance',
        'unii' => 'substance',
        'substance_id' => 'substance',
        'text_id' => 'description',
        'asset_id' => 'media',
        'leaflet_id' => 'media',
    ];

    /** @return list<string> */
    public static function lanes(): array
    {
        return array_map(static fn (Lane $lane): string => $lane->value, Lane::cases());
    }

    public static function prefix(string $lane): string
    {
        return Lane::from($lane)->prefix();
    }

    /** Lane atom for a wire entity name ("description" => 'description'), or null if unknown. */
    public static function parse(string $name): ?string
    {
        return self::tryParse($name)?->value;
    }

    public static function tryParse(string $name): ?Lane
    {
        return Lane::tryFrom($name);
    }

    /** Lane of one code scheme. 'uuid' is shared (null); unknown schemes default to 'product'. */
    public static function laneOfScheme(string $scheme): ?string
    {
        $lane = self::ofScheme($scheme);

        return $lane?->value;
    }

    /**
     * Typed lane of one code scheme. 'uuid' is shared (null); unknown schemes default to Product.
     * Synthetic lane-anchor schemes ({@see IdentityScheme}) resolve via their enum.
     */
    public static function ofScheme(string $scheme): ?Lane
    {
        if ($scheme === 'uuid') {
            return null;
        }

        $identity = IdentityScheme::tryFrom($scheme);
        if ($identity !== null) {
            return $identity->lane();
        }

        return isset(self::LANE_OF[$scheme])
            ? Lane::from(self::LANE_OF[$scheme])
            : Lane::Product;
    }

    /** Lane of a surrogate key, by its prefix ("SUB_3" => 'substance'). */
    public static function laneOfKey(string $key): string
    {
        return self::ofKey($key)->value;
    }

    public static function ofKey(string $key): Lane
    {
        foreach ([Lane::Substance, Lane::Description, Lane::Media] as $lane) {
            if (str_starts_with($key, $lane->prefix().'_')) {
                return $lane;
            }
        }

        return Lane::Product;
    }

    /**
     * Lane of an identity claim: the unique lane among its codes' schemes (uuid is neutral),
     * falling back to an explicit `entity` in the claim data, else 'product'. Two lanes in one
     * claim is a contract violation — returns ['error', ['mixed_lanes', sortedLanes]].
     *
     * @return array{0: string, 1: mixed}
     */
    public static function ofClaim(Claim $claim): array
    {
        $lanes = [];
        foreach ($claim->data['codes'] as $code) {
            $lane = self::laneOfScheme($code[0]);
            if ($lane !== null) {
                $lanes[$lane] = true;
            }
        }
        $lanes = array_keys($lanes);

        if ($lanes === []) {
            return ['ok', $claim->data['entity'] ?? 'product'];
        }
        if (count($lanes) === 1) {
            return ['ok', $lanes[0]];
        }
        sort($lanes);

        return ['error', ['mixed_lanes', $lanes]];
    }

    /**
     * The identity claims of one lane (mixed-lane claims belong to no lane).
     *
     * @param list<Claim> $claims
     * @return list<Claim>
     */
    public static function identityClaims(array $claims, string $lane): array
    {
        $out = [];
        foreach ($claims as $c) {
            if ($c->kind === 'identity' && self::ofClaim($c) === ['ok', $lane]) {
                $out[] = $c;
            }
        }

        return $out;
    }

    /**
     * Partition a ledger's members map by each key's lane. Returns lane => (key => code-set).
     *
     * @param array<string, array<string, array{0: string, 1: string}>> $members
     * @return array<string, array<string, array<string, array{0: string, 1: string}>>>
     */
    public static function partitionMembers(array $members): array
    {
        $out = array_fill_keys(self::LANES, []);
        foreach ($members as $key => $codes) {
            $out[self::laneOfKey($key)][$key] = $codes;
        }

        return $out;
    }

    /**
     * A fresh ledger per lane, each minting under its own prefix.
     *
     * @return array<string, LedgerState>
     */
    public static function newLedgers(): array
    {
        $out = [];
        foreach (self::LANES as $lane) {
            $out[$lane] = IdentityLedger::new(self::prefix($lane));
        }

        return $out;
    }

    /**
     * Cluster + reconcile each lane's identity claims against that lane's own ledger. Returns
     * [identityEvents, ledgers]; events come out in lane order (product first).
     *
     * @param list<Claim> $liveClaims
     * @param array<string, array{0: string, 1: string}> $shared a code-set
     * @param array<string, LedgerState> $ledgers
     * @return array{0: list<DomainEvent>, 1: array<string, LedgerState>}
     */
    public static function reconcile(array $liveClaims, array $shared, array $ledgers, mixed $at): array
    {
        $events = [];
        foreach (self::LANES as $lane) {
            $claims = self::identityClaims($liveClaims, $lane);
            if ($claims === []) {
                continue;
            }
            $evidence = array_values(array_filter(
                $liveClaims,
                static fn (Claim $claim): bool => $claim->kind === 'identity_evidence'
                    && self::laneOfScheme($claim->data['left'][0]) === $lane
                    && self::laneOfScheme($claim->data['right'][0]) === $lane,
            ));
            $clusters = Cluster::variants(array_merge($claims, $evidence), $shared);
            $laneEvents = IdentityLedger::decide($ledgers[$lane], ['reconcile', $clusters, $shared, $at]);
            $state = $ledgers[$lane];
            foreach ($laneEvents as $e) {
                $state = IdentityLedger::evolve($state, $e);
            }
            $ledgers[$lane] = $state;
            foreach ($laneEvents as $e) {
                $events[] = $e;
            }
        }

        return [$events, $ledgers];
    }
}
