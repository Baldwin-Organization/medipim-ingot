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

        // Flatten each lane's members once — owner() scanned every member set per edge endpoint.
        $mediaIndex = self::ownerIndex($lanes['media']);
        $subIndex = self::ownerIndex($lanes['substance']);
        $descIndex = self::ownerIndex($lanes['description']);

        $variants = [];
        foreach ($lanes['product'] as $key => $codes) {
            $substances = self::resolveSubstances($codes, $edges, $subIndex);
            $variants[] = new Variant(
                $key,
                Sets::valuesSorted($codes),
                self::resolveAttributes($key, $codes, $attrs, $priority, $overrides['attr']),
                self::resolveProduct($key, $codes, $groups, $priority, $overrides['product']),
                array_merge(
                    self::resolveMedia($codes, $media, $priority),
                    self::resolveDepicted($codes, $edges, $lanes['media'], $mediaIndex, $attrs, $priority)
                ),
                self::resolveCategories($codes, $edges),
                $substances,
                self::resolveDescriptions($codes, $edges, $lanes, $subIndex, $descIndex, $substances, $attrs, $priority),
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
        // $key/$attrOverrides are unused pending steward-override support (Elixir's apply_override
        // was deliberately dropped on the 422156 path) — kept for the Elixir-parity signature.
        return self::laneAttributes($codes, $attrs, $priority);
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
                if ($r < $bestRank) {
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
     * @param array<string, string> $subIndex
     * @return list<array<string,mixed>>
     */
    private static function resolveSubstances(array $codes, array $edges, array $subIndex): array
    {
        [$byKey, $keyOrder] = self::groupEdgesByOwner($edges, $codes, $subIndex, 'contains', 'from', 'to');

        $out = [];
        foreach ($byKey as $ok => $es) {
            $codesList = [];
            $codeSeen = [];
            foreach ($es as $e) {
                $ck = self::pairKey($e->data['to']);
                if (!isset($codeSeen[$ck])) {
                    $codeSeen[$ck] = true;
                    $codesList[] = $e->data['to'];
                }
            }
            usort($codesList, static fn (array $a, array $b): int => [$a[0], $a[1]] <=> [$b[0], $b[1]]);
            $out[] = ['key' => $keyOrder[$ok], 'codes' => $codesList, 'sources' => self::sortedUniqueSources($es)];
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
     * @param array<string, string> $mediaIndex
     * @param list<Claim> $attrs
     * @return list<array<string,mixed>>
     */
    private static function resolveDepicted(array $codes, array $edges, array $mediaMembers, array $mediaIndex, array $attrs, Priority|callable $priority): array
    {
        [$byKey, $keyOrder] = self::groupEdgesByOwner($edges, $codes, $mediaIndex, 'depicts', 'to', 'from');

        $out = [];
        foreach ($byKey as $ok => $es) {
            $owner = $keyOrder[$ok];
            $assetCodes = is_string($owner) && isset($mediaMembers[$owner])
                ? $mediaMembers[$owner]
                : Sets::of([self::ownerAsCode($owner)]);
            $attributes = self::laneAttributes($assetCodes, $attrs, $priority);

            $sources = self::sortedUniqueSources($es);

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
     * @param array<string, string> $subIndex
     * @param array<string, string> $descIndex
     * @param list<array<string,mixed>> $substances this variant's resolveSubstances result
     * @param list<Claim> $attrs
     * @return list<array<string,mixed>>
     */
    private static function resolveDescriptions(array $codes, array $edges, array $lanes, array $subIndex, array $descIndex, array $substances, array $attrs, Priority|callable $priority): array
    {
        $describes = [];
        foreach ($edges as $e) {
            if ($e->data['relation'] === 'describes') {
                $describes[] = $e;
            }
        }

        // Substance keys this variant contains (the `via` source set).
        $contained = [];
        foreach ($substances as $sub) {
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
            $owner = self::ownerOf($subIndex, $e->data['to']);
            $ok = self::ownerKey($owner);
            if (isset($contained[$ok])) {
                $entries[] = [$e, ['substance', $owner]];
            }
        }

        // Drop steward-suppressed pairings: a suppress edge (description code → carried product
        // code) hides every pairing resolving to that description record. One pass over the
        // edges builds the suppressed-key set; suppressed() rescanned them per entry.
        $suppressedKeys = [];
        foreach ($edges as $s) {
            if ($s->data['relation'] === 'suppress' && Sets::member($codes, $s->data['to'])) {
                $suppressedKeys[self::ownerKey(self::ownerOf($descIndex, $s->data['from']))] = true;
            }
        }
        $kept = [];
        foreach ($entries as $entry) {
            if (!isset($suppressedKeys[self::ownerKey(self::ownerOf($descIndex, $entry[0]->data['from']))])) {
                $kept[] = $entry;
            }
        }

        // Group by [owner-desc-key, route].
        /** @var array<string, array{key: mixed, route: mixed, entries: list<array{0: Claim, 1: mixed}>}> $groups */
        $groups = [];
        foreach ($kept as $entry) {
            [$e, $route] = $entry;
            $descOwner = self::ownerOf($descIndex, $e->data['from']);
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

            $out[] = [
                'key' => $key,
                'via' => $g['route'],
                'asserted_by' => self::sortedUniqueSources(array_column($g['entries'], 0)),
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
     * A lane's members flattened to code key => owning member key. First member wins, matching
     * the scan order the per-endpoint owner lookup used to walk.
     *
     * @param array<string, array<string, array{0: string, 1: string}>> $members
     * @return array<string, string>
     */
    private static function ownerIndex(array $members): array
    {
        $index = [];
        foreach ($members as $k => $set) {
            foreach ($set as $ck => $_code) {
                $index[$ck] ??= $k;
            }
        }

        return $index;
    }

    /**
     * Resolve an edge endpoint to the key that currently owns it; an endpoint with no identity
     * claim resolves to ITSELF (the code is the identity until a record exists).
     *
     * @param array<string, string> $index from {@see ownerIndex}
     * @param array{0: string, 1: string} $code
     * @return string|array{0: string, 1: string}
     */
    private static function ownerOf(array $index, array $code): string|array
    {
        return $index[Codes::key($code)] ?? $code;
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

    /**
     * Group edges of $relation whose $memberEnd code the variant carries, keyed by the resolved
     * owner of their $ownerEnd — the shared shape of the substances and depicted resolvers.
     *
     * @param list<Claim> $edges
     * @param array<string, array{0: string, 1: string}> $codes
     * @param array<string, string> $index from {@see ownerIndex}
     * @return array{0: array<string, list<Claim>>, 1: array<string, string|array{0: string, 1: string}>}
     */
    private static function groupEdgesByOwner(array $edges, array $codes, array $index, string $relation, string $memberEnd, string $ownerEnd): array
    {
        $byKey = [];
        $keyOrder = [];
        foreach ($edges as $e) {
            if ($e->data['relation'] === $relation && Sets::member($codes, $e->data[$memberEnd])) {
                $owner = self::ownerOf($index, $e->data[$ownerEnd]);
                $ok = is_array($owner) ? self::pairKey($owner) : (string) $owner;
                if (!isset($byKey[$ok])) {
                    $byKey[$ok] = [];
                    $keyOrder[$ok] = $owner;
                }
                $byKey[$ok][] = $e;
            }
        }

        return [$byKey, $keyOrder];
    }

    /**
     * @param list<Claim> $claims
     * @return list<string> distinct sources, sorted
     */
    private static function sortedUniqueSources(array $claims): array
    {
        $out = [];
        $seen = [];
        foreach ($claims as $c) {
            if (!isset($seen[$c->source])) {
                $seen[$c->source] = true;
                $out[] = $c->source;
            }
        }
        sort($out, SORT_STRING);

        return $out;
    }
}
