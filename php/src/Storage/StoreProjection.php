<?php

declare(strict_types=1);

namespace Ingot\Storage;

use Ingot\Catalog;
use Ingot\Decision;
use Ingot\DimensionAliases;
use Ingot\Events;
use Ingot\GoldenRecords;
use Ingot\Priority;
use Ingot\Sets;
use Ingot\Substrate;

/**
 * The store-backed read side (gh-118): a RESOLVED golden record for one surrogate key straight from
 * a {@see ClaimStore}, without re-decoding envelopes or folding the whole log. The counterpart of
 * {@see \Ingot\GoldenRecords::project} for the "current truth" case (per-key snapshot), sharing
 * Catalog's decision logic so both paths return identical {@see Decision} shapes.
 */
final class StoreProjection
{
    /**
     * The resolved record for `$surrogateKey`, following merge redirects to the surviving key,
     * or null when the key (after redirects) has no snapshot. `$policy` is the survivorship
     * policy — a {@see Priority} or an injected rank fn (e.g. MedipimPolicy) — defaulting to the
     * permissive unranked priority, exactly as {@see \Ingot\GoldenRecords::project}. `$aliases`
     * is the dimension-alias seam ({@see DimensionAliases}), applied to the snapshot's claims
     * before grouping so a snapshot written before a field rename still resolves as one dimension.
     *
     * @param array<string,string> $aliases
     * @return array{key: string, lane: string, codes: list<array{0:string,1:string}>, product: Decision, attributes: list<array{0:string,1:Decision}>}|null
     */
    public static function record(ClaimStore $store, string $surrogateKey, Priority|callable|null $policy = null, array $aliases = []): ?array
    {
        $policy ??= GoldenRecords::defaultPriority();

        $key = $store->resolveSurrogate($surrogateKey);
        $info = $store->loadKeys([$key])[$key] ?? null;
        if ($info === null) {
            return null;
        }

        // The snapshot's claims are the key's stored current view; collapse once more so a view
        // saved mid-history (backfill keeps intervals) still reads last-wins per slot.
        $claims = [];
        foreach ($info['claims'] as $c) {
            $claims[] = Events::fromArray($c);
        }
        $live = Substrate::current(DimensionAliases::normalize($claims, $aliases));

        $attrs = [];
        $groups = [];
        foreach ($live as $c) {
            if ($c->kind === 'attribute') {
                $attrs[] = $c;
            } elseif ($c->kind === 'grouping') {
                $groups[] = $c;
            }
        }

        return [
            'key' => $key,
            'lane' => $info['lane'],
            'codes' => Sets::valuesSorted($info['codes']),
            'product' => Catalog::resolveProductFromClaims($info['codes'], $groups, $policy),
            'attributes' => Catalog::laneAttributes($info['codes'], $attrs, $policy),
        ];
    }
}
