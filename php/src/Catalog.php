<?php

declare(strict_types=1);

namespace Ingot;

/**
 * The read projection — ported from `Catalog` in lib/golden_record_core.ex.
 *
 * `project` folds the per-lane members + the current claim view into customer-facing records:
 * products ▸ variants ▸ {codes, survivorship attributes, product label, media, categories,
 * substances, derived descriptions}. Visibility is DERIVED at read time — edges are resolved to
 * their current owner key on every read, so a merge/split converges every product's view with no
 * writes. On the 422156 path: media arrives via `depicts` edges (MED_* records), descriptions via
 * `describes` edges (DSC_* records), categories via `member_of` edges, substances are empty.
 */
final class Catalog
{
    /**
     * @param array<string, array<string, array{0: string, 1: string}>> $members key => code-set (all lanes)
     * @param list<Claim> $liveClaims current claim view
     * @param array{attr: array<string, mixed>, product: array<string, mixed>} $overrides
     * @return list<GoldenRecord>
     */
    public static function project(array $members, array $liveClaims, Priority|callable $priority, array $overrides): array
    {
        $lanes = Lanes::partitionMembers($members);
        $attrs = self::filterKind($liveClaims, 'attribute');
        $groups = self::filterKind($liveClaims, 'grouping');
        $media = self::filterKind($liveClaims, 'media');
        $edges = self::filterKind($liveClaims, 'edge');

        $variants = [];
        foreach ($lanes['product'] as $key => $codes) {
            $variants[] = new Variant(
                $key,
                Sets::valuesSorted($codes),
                self::resolveAttributes($key, $codes, $attrs, $priority, $overrides['attr']),
                self::resolveProduct($key, $codes, $groups, $priority, $overrides['product']),
                array_merge(
                    self::resolveMedia($codes, $media, $priority),
                    self::resolveDepicted($codes, $edges, $lanes['media'], $attrs, $priority)
                ),
                self::resolveCategories($codes, $edges),
                self::resolveSubstances($codes, $edges, $lanes['substance']),
                self::resolveDescriptions($codes, $edges, $lanes, $attrs, $priority),
            );
        }

        // Group variants by their product label, sort products by label, variants by key.
        /** @var array<string, array{product: mixed, variants: list<Variant>}> $byProduct */
        $byProduct = [];
        $order = [];
        foreach ($variants as $v) {
            $pk = self::scalarKey($v->product->value);
            if (!isset($byProduct[$pk])) {
                $byProduct[$pk] = ['product' => $v->product->value, 'variants' => []];
                $order[] = $pk;
            }
            $byProduct[$pk]['variants'][] = $v;
        }

        $products = [];
        foreach ($order as $pk) {
            $products[] = $byProduct[$pk];
        }
        usort($products, static fn (array $a, array $b): int => self::compareProductValues($a['product'], $b['product']));

        $records = [];
        foreach ($products as $p) {
            $ordered = $p['variants'];
            usort($ordered, static fn (Variant $a, Variant $b): int => strcmp($a->key, $b->key));
            $records[] = new GoldenRecord($p['product'], $ordered);
        }

        return $records;
    }

    /**
     * @param array<string, array{0: string, 1: string}> $codes
     * @param list<Claim> $attrs
     * @param array<string, mixed> $attrOverrides
     * @return list<array{0: string, 1: Decision}>
     */
    private static function resolveAttributes(string $key, array $codes, array $attrs, Priority|callable $priority, array $attrOverrides): array
    {
        $decisions = Survivorship::fieldDecisions($codes, $attrs, $priority);

        $out = [];
        foreach ($decisions as [$field, $base]) {
            $out[] = [$field, $base]; // no overrides on the 422156 path (empty maps)
        }
        usort($out, static fn (array $a, array $b): int => strcmp($a[0], $b[0]));

        return $out;
    }

    /**
     * @param array<string, array{0: string, 1: string}> $codes
     * @param list<Claim> $groups
     * @param array<string, mixed> $productOverrides
     */
    private static function resolveProduct(string $key, array $codes, array $groups, Priority|callable $priority, array $productOverrides): Decision
    {
        if (array_key_exists($key, $productOverrides)) {
            return new Decision($productOverrides[$key], 'steward', 'resolved_by_steward', []);
        }

        return self::resolveProductFromClaims($codes, $groups, $priority);
    }

    /**
     * @param array<string, array{0: string, 1: string}> $codes
     * @param list<Claim> $groups
     */
    private static function resolveProductFromClaims(array $codes, array $groups, Priority|callable $priority): Decision
    {
        $entries = [];
        foreach ($groups as $g) {
            if (Sets::member($codes, $g->data['code'])) {
                $entries[] = ['source' => $g->source, 'value' => $g->data['product'], 'order' => $g->order];
            }
        }

        if ($entries === []) {
            return new Decision(['none', '—'], null, 'resolved', []);
        }

        $base = Survivorship::decide('product', $entries, $priority);
        $distinct = [];
        foreach ($entries as $e) {
            $distinct[self::scalarKey($e['value'])] = true;
        }
        if (count($distinct) > 1) {
            return new Decision(null, null, 'needs_review', $base->candidates);
        }

        return $base;
    }

    /**
     * Legacy media-claim resolution (dedup by asset, highest-priority source wins).
     *
     * @param array<string, array{0: string, 1: string}> $codes
     * @param list<Claim> $media
     * @return list<array<string,mixed>>
     */
    private static function resolveMedia(array $codes, array $media, Priority|callable $priority): array
    {
        /** @var array<string, list<Claim>> $byAsset */
        $byAsset = [];
        foreach ($media as $m) {
            if (Sets::member($codes, $m->data['target'])) {
                $byAsset[self::scalarKey($m->data['asset'])][] = $m;
            }
        }

        $rank = Survivorship::rankFn($priority);

        $out = [];
        foreach ($byAsset as $claims) {
            $best = $claims[0];
            $bestRank = $rank('media', $best->source);
            foreach ($claims as $m) {
                $r = $rank('media', $m->source);
                if (self::infLt($r, $bestRank)) {
                    $bestRank = $r;
                    $best = $m;
                }
            }
            $out[] = [
                'asset' => $best->data['asset'],
                'role' => $best->data['role'],
                'source' => $best->source,
                'uri' => $best->data['uri'],
            ];
        }

        usort($out, static function (array $a, array $b): int {
            return [$a['role'] !== 'primary', self::scalarKey($a['asset'])]
                <=> [$b['role'] !== 'primary', self::scalarKey($b['asset'])];
        });

        return $out;
    }

    /**
     * Categories via `member_of` edges: the collection {namespace, member} pairs this record's
     * codes point at, unique + sorted.
     *
     * @param array<string, array{0: string, 1: string}> $codes
     * @param list<Claim> $edges
     * @return list<array{0: string, 1: string}>
     */
    private static function resolveCategories(array $codes, array $edges): array
    {
        $seen = [];
        $out = [];
        foreach ($edges as $e) {
            if ($e->data['relation'] === 'member_of' && Sets::member($codes, $e->data['from'])) {
                $to = $e->data['to'];
                $k = self::pairKey($to);
                if (!isset($seen[$k])) {
                    $seen[$k] = true;
                    $out[] = $to;
                }
            }
        }
        usort($out, static fn (array $a, array $b): int => self::compareStringPair($a, $b));

        return $out;
    }

    /**
     * Substances via `contains` edges, grouped by the substance key that currently owns the `to`.
     *
     * @param array<string, array{0: string, 1: string}> $codes
     * @param list<Claim> $edges
     * @param array<string, array<string, array{0: string, 1: string}>> $subMembers
     * @return list<array<string,mixed>>
     */
    private static function resolveSubstances(array $codes, array $edges, array $subMembers): array
    {
        /** @var array<string, list<Claim>> $byKey */
        $byKey = [];
        $keyOrder = [];
        foreach ($edges as $e) {
            if ($e->data['relation'] === 'contains' && Sets::member($codes, $e->data['from'])) {
                $owner = self::owner($subMembers, $e->data['to']);
                $ok = is_array($owner) ? self::pairKey($owner) : (string) $owner;
                if (!isset($byKey[$ok])) {
                    $byKey[$ok] = [];
                    $keyOrder[$ok] = $owner;
                }
                $byKey[$ok][] = $e;
            }
        }

        $out = [];
        foreach ($byKey as $ok => $es) {
            $codesList = [];
            $codeSeen = [];
            $sources = [];
            $srcSeen = [];
            foreach ($es as $e) {
                $ck = self::pairKey($e->data['to']);
                if (!isset($codeSeen[$ck])) {
                    $codeSeen[$ck] = true;
                    $codesList[] = $e->data['to'];
                }
                if (!isset($srcSeen[$e->source])) {
                    $srcSeen[$e->source] = true;
                    $sources[] = $e->source;
                }
            }
            usort($codesList, static fn (array $a, array $b): int => [$a[0], $a[1]] <=> [$b[0], $b[1]]);
            sort($sources, SORT_STRING);
            $out[] = ['key' => $keyOrder[$ok], 'codes' => $codesList, 'sources' => $sources];
        }

        usort($out, static fn (array $a, array $b): int => self::compareOwner($a['key'], $b['key']));

        return $out;
    }

    /**
     * Depicted media via `depicts` edges (the first-class media-lane path, MED_* records).
     *
     * @param array<string, array{0: string, 1: string}> $codes
     * @param list<Claim> $edges
     * @param array<string, array<string, array{0: string, 1: string}>> $mediaMembers
     * @param list<Claim> $attrs
     * @return list<array<string,mixed>>
     */
    private static function resolveDepicted(array $codes, array $edges, array $mediaMembers, array $attrs, Priority|callable $priority): array
    {
        /** @var array<string, list<Claim>> $byKey */
        $byKey = [];
        $keyOrder = [];
        foreach ($edges as $e) {
            if ($e->data['relation'] === 'depicts' && Sets::member($codes, $e->data['to'])) {
                $owner = self::owner($mediaMembers, $e->data['from']);
                $ok = is_array($owner) ? self::pairKey($owner) : (string) $owner;
                if (!isset($byKey[$ok])) {
                    $byKey[$ok] = [];
                    $keyOrder[$ok] = $owner;
                }
                $byKey[$ok][] = $e;
            }
        }

        $out = [];
        foreach ($byKey as $ok => $es) {
            $owner = $keyOrder[$ok];
            $assetCodes = is_string($owner) && isset($mediaMembers[$owner])
                ? $mediaMembers[$owner]
                : Sets::of([self::ownerAsCode($owner)]);
            $attributes = self::laneAttributes($assetCodes, $attrs, $priority);

            $sources = [];
            $srcSeen = [];
            foreach ($es as $e) {
                if (!isset($srcSeen[$e->source])) {
                    $srcSeen[$e->source] = true;
                    $sources[] = $e->source;
                }
            }
            sort($sources, SORT_STRING);

            $out[] = [
                'asset' => $owner,
                'role' => self::attrValue($attributes, 'role', 'secondary'),
                'source' => $sources[0],
                'uri' => self::attrValue($attributes, 'uri', null),
            ];
        }

        usort($out, static fn (array $a, array $b): int => self::compareOwner($a['asset'], $b['asset']));

        return $out;
    }

    /**
     * Derived descriptions (gr-sw0): descriptions tagged directly to the variant, plus
     * descriptions tagged to any substance it contains, minus steward-suppressed pairings.
     *
     * @param array<string, array{0: string, 1: string}> $codes
     * @param list<Claim> $edges
     * @param array<string, array<string, array{0: string, 1: string}>> $lanes lane => members
     * @param list<Claim> $attrs
     * @return list<array<string,mixed>>
     */
    private static function resolveDescriptions(array $codes, array $edges, array $lanes, array $attrs, Priority|callable $priority): array
    {
        $describes = [];
        foreach ($edges as $e) {
            if ($e->data['relation'] === 'describes') {
                $describes[] = $e;
            }
        }

        // Substance keys this variant contains (the `via` source set).
        $contained = [];
        foreach (self::resolveSubstances($codes, $edges, $lanes['substance']) as $sub) {
            $contained[self::ownerKey($sub['key'])] = true;
        }

        // direct: described codes the variant carries; via: described codes a contained substance owns.
        $entries = []; // list of [edge, route]
        foreach ($describes as $e) {
            if (Sets::member($codes, $e->data['to'])) {
                $entries[] = [$e, 'direct'];
            }
        }
        foreach ($describes as $e) {
            $owner = self::owner($lanes['substance'], $e->data['to']);
            $ok = self::ownerKey($owner);
            if (isset($contained[$ok])) {
                $entries[] = [$e, ['substance', $owner]];
            }
        }

        // Drop steward-suppressed pairings.
        $kept = [];
        foreach ($entries as $entry) {
            if (!self::suppressed($entry, $codes, $edges, $lanes['description'])) {
                $kept[] = $entry;
            }
        }

        // Group by [owner-desc-key, route].
        /** @var array<string, array{key: mixed, route: mixed, entries: list<array{0: Claim, 1: mixed}>}> $groups */
        $groups = [];
        foreach ($kept as $entry) {
            [$e, $route] = $entry;
            $descOwner = self::owner($lanes['description'], $e->data['from']);
            $gk = self::ownerKey($descOwner)."\x1e".self::routeKey($route);
            if (!isset($groups[$gk])) {
                $groups[$gk] = ['key' => $descOwner, 'route' => $route, 'entries' => []];
            }
            $groups[$gk]['entries'][] = $entry;
        }

        $out = [];
        foreach ($groups as $g) {
            $key = $g['key'];
            $descCodes = is_string($key) && isset($lanes['description'][$key])
                ? $lanes['description'][$key]
                : Sets::of([self::ownerAsCode($key)]);

            $assertedBy = [];
            $seen = [];
            foreach ($g['entries'] as [$e, $_route]) {
                if (!isset($seen[$e->source])) {
                    $seen[$e->source] = true;
                    $assertedBy[] = $e->source;
                }
            }
            sort($assertedBy, SORT_STRING);

            $out[] = [
                'key' => $key,
                'via' => $g['route'],
                'asserted_by' => $assertedBy,
                'attributes' => self::laneAttributes($descCodes, $attrs, $priority),
            ];
        }

        // Sort by {via != :direct, via, key}.
        usort($out, static function (array $a, array $b): int {
            $da = $a['via'] === 'direct' ? 0 : 1;
            $db = $b['via'] === 'direct' ? 0 : 1;
            if ($da !== $db) {
                return $da <=> $db;
            }
            $cmp = strcmp(self::routeKey($a['via']), self::routeKey($b['via']));
            if ($cmp !== 0) {
                return $cmp;
            }

            return self::compareOwner($a['key'], $b['key']);
        });

        return $out;
    }

    /**
     * A steward `suppress` edge (description code → product code) hides ONE pairing: it must
     * resolve to the same description record AND target a code this variant carries.
     *
     * @param array{0: Claim, 1: mixed} $entry
     * @param array<string, array{0: string, 1: string}> $codes
     * @param list<Claim> $edges
     * @param array<string, array<string, array{0: string, 1: string}>> $descMembers
     */
    private static function suppressed(array $entry, array $codes, array $edges, array $descMembers): bool
    {
        [$e, $_route] = $entry;
        $descKey = self::ownerKey(self::owner($descMembers, $e->data['from']));

        foreach ($edges as $s) {
            if ($s->data['relation'] === 'suppress'
                && Sets::member($codes, $s->data['to'])
                && self::ownerKey(self::owner($descMembers, $s->data['from'])) === $descKey
            ) {
                return true;
            }
        }

        return false;
    }

    /**
     * Resolve an edge endpoint to the key that currently owns it; an endpoint with no identity
     * claim resolves to ITSELF (the code is the identity until a record exists).
     *
     * @param array<string, array<string, array{0: string, 1: string}>> $members
     * @param array{0: string, 1: string} $code
     * @return string|array{0: string, 1: string}
     */
    private static function owner(array $members, array $code): string|array
    {
        foreach ($members as $k => $set) {
            if (Sets::member($set, $code)) {
                return $k;
            }
        }

        return $code;
    }

    /**
     * @param array<string, array{0: string, 1: string}> $codes
     * @param list<Claim> $attrs
     * @return list<array{0: string, 1: Decision}>
     */
    private static function laneAttributes(array $codes, array $attrs, Priority|callable $priority): array
    {
        $decisions = Survivorship::fieldDecisions($codes, $attrs, $priority);
        usort($decisions, static fn (array $a, array $b): int => strcmp($a[0], $b[0]));

        return $decisions;
    }

    /**
     * @param list<array{0: string, 1: Decision}> $attributes
     */
    private static function attrValue(array $attributes, string $field, mixed $default): mixed
    {
        foreach ($attributes as [$f, $decision]) {
            if ($f === $field) {
                return $decision->value;
            }
        }

        return $default;
    }

    // ── helpers ─────────────────────────────────────────────────────────────────

    /**
     * @param list<Claim> $claims
     * @return list<Claim>
     */
    private static function filterKind(array $claims, string $kind): array
    {
        $out = [];
        foreach ($claims as $c) {
            if ($c->kind === $kind) {
                $out[] = $c;
            }
        }

        return $out;
    }

    /** @param string|array{0: string, 1: string} $owner */
    private static function ownerKey(string|array $owner): string
    {
        return is_array($owner) ? self::pairKey($owner) : $owner;
    }

    /**
     * @param string|array{0: string, 1: string} $owner
     * @return array{0: string, 1: string}
     */
    private static function ownerAsCode(string|array $owner): array
    {
        // A description/media key resolving to itself: the owner key IS used as the lone "code".
        return is_array($owner) ? $owner : [$owner, $owner];
    }

    /**
     * @param string|array{0: string, 1: string} $a
     * @param string|array{0: string, 1: string} $b
     */
    private static function compareOwner(string|array $a, string|array $b): int
    {
        // Both substance/media/description owners are surrogate keys (strings) on every real path.
        return strcmp(self::ownerKey($a), self::ownerKey($b));
    }

    /** @param array{0: string, 1: string} $pair */
    private static function pairKey(array $pair): string
    {
        return $pair[0]."\x1f".$pair[1];
    }

    /**
     * Lexicographic comparison of two [scheme/collection, value] pairs — PHP's `<=>` would compare
     * numeric-looking strings NUMERICALLY ("1035" > "44"), but Elixir's term order is byte-wise.
     *
     * @param array{0: string, 1: string} $a
     * @param array{0: string, 1: string} $b
     */
    private static function compareStringPair(array $a, array $b): int
    {
        $c = strcmp($a[0], $b[0]);

        return $c !== 0 ? $c : strcmp($a[1], $b[1]);
    }

    private static function routeKey(mixed $route): string
    {
        if (is_string($route)) {
            return $route;
        }
        if (is_array($route)) {
            // ['substance', ownerKeyOrCode]
            return $route[0].':'.self::ownerKey($route[1]);
        }

        return (string) $route;
    }

    private static function scalarKey(mixed $value): string
    {
        if (is_array($value)) {
            // tuples like ['none','—'] or ['mpn','ALPHA']
            return 't:'.implode("\x1f", array_map(static fn ($x): string => (string) $x, $value));
        }

        return match (true) {
            is_bool($value) => 'b:'.($value ? '1' : '0'),
            is_int($value) => 'i:'.$value,
            is_float($value) => 'f:'.$value,
            is_string($value) => 's:'.$value,
            $value === null => 'n:',
            default => 'x:'.json_encode($value),
        };
    }

    private static function compareProductValues(mixed $a, mixed $b): int
    {
        // Elixir sorts product labels with the default term order. Real 422156 labels are integers
        // (the legacy entity); we compare numerically when both are ints, else by string form.
        if (is_int($a) && is_int($b)) {
            return $a <=> $b;
        }
        if (is_array($a) && is_array($b)) {
            return [$a[0] ?? '', $a[1] ?? ''] <=> [$b[0] ?? '', $b[1] ?? ''];
        }

        return strcmp(self::scalarKey($a), self::scalarKey($b));
    }

    private static function infLt(int|float $a, int|float $b): bool
    {
        return $a < $b;
    }
}
