<?php

declare(strict_types=1);

namespace Ingot;

/**
 * The medipim reference adapter — ported from `ClaimMapping` (lib/ingest/claim_mapping.ex).
 *
 * Folds contract-C HistoryEnvelopes into canonical claims (`canonicalClaims`) and composes them
 * into engine claims plus the `shared` code set (`build`). Per listing = (legacy_entity, source):
 * replay identity events into code-set `Period`s, canonicalize/partition, then synthesize identity /
 * grouping / attribute / member_of claims, plus first-class lane records (media + descriptions +
 * leaflets) tied back by depicts/describes edges. Claims are stamped with a chronological `order`.
 *
 * Internals speak the domain value objects — `Code`, `CodeSet`, `Period`, `Listing` — so the fold
 * reads as language; the public API keeps the engine's array shapes (`Sets` code-sets, wire maps).
 */
final class ClaimMapping
{
    // artg_id (gr-sx7.1): an identity code one ARTG registration shares across pack sizes — never fuses.
    private const NON_BRIDGING_SCHEMES = ['mpn', 'supplier_ref', 'artg_id'];

    /** medipim edge collections that reference first-class entities. collection => [scheme, lane, relation]. */
    private const LANE_COLLECTIONS = [
        'descriptions' => ['text_id', 'description', 'describes'],
        'media' => ['asset_id', 'media', 'depicts'],
        // AU leaflets (gr-sx7.1): own scheme — leaflet ids live in a different medipim table
        // than media ids, so sharing asset_id would collide id-spaces.
        'leaflets' => ['leaflet_id', 'media', 'depicts'],
    ];

    // One fold's working state: every output of a build reads the same per-listing identity
    // periods, and canonical/rejected ask the same codesAt questions — so one instance per
    // build holds the fold and its memos, and is unreachable again when build() returns.

    /** @var array<string, list<Period>> the per-listing identity fold every output reads */
    private readonly array $periods;

    /** @var array<string, list<Code>> codesAt memo, keyed (entity, source, at) */
    private array $codesAtMemo = [];

    /** @var array<string, list<string>>|null lazy entity → listing-keys index for unsourced lookups */
    private ?array $entityListings = null;

    /** @param list<Envelope> $envelopes */
    private function __construct(private readonly array $envelopes)
    {
        $this->periods = self::listingPeriods($envelopes);
    }

    /**
     * Map envelopes to ['claims' => [Claim...], 'shared' => code-set].
     *
     * @param list<Envelope> $envelopes
     * @return array{claims: list<Claim>, shared: array<string, array{0: string, 1: string}>, rejected: list<array<string,mixed>>}
     */
    public static function build(array $envelopes): array
    {
        $fold = new self($envelopes);

        return [
            'claims' => self::stamp(CanonicalClaims::toEngineBang($fold->canonical())),
            'shared' => self::sharedCodes(self::finalCodes($fold->periods))->toSets(),
            'rejected' => $fold->rejectedClaims(),
        ];
    }

    /**
     * Stage (a): the canonical claims (wire-shaped maps) in emission order.
     *
     * @param list<Envelope> $envelopes
     * @return list<array<string,mixed>>
     */
    public static function canonicalClaims(array $envelopes): array
    {
        return (new self($envelopes))->canonical();
    }

    /**
     * Just the folded, canonicalized code-set per listing — keyed "entity\x1fsource", in the
     * engine's `Sets` shape.
     *
     * @param list<Envelope> $envelopes
     * @return array<string, array<string, array{0: string, 1: string}>>
     */
    public static function listings(array $envelopes): array
    {
        return array_map(static fn (CodeSet $codes): array => $codes->toSets(), self::finalCodes(self::listingPeriods($envelopes)));
    }

    /**
     * @return list<array<string,mixed>>
     */
    private function canonical(): array
    {
        // A claim is ABOUT a code — cnk, ean, cn — and about ONE OR MORE of them. So the anchor is
        // every code the asserting source itself held AT THE TIME it spoke, read out of that
        // listing's periods. Mirrors ClaimMapping.codes_at/4 in lib/ingest/claim_mapping.ex.
        $periods = $this->periods;

        $orderedKeys = array_keys($periods);
        sort($orderedKeys, SORT_STRING);

        $identity = [];
        $grouping = [];
        foreach ($orderedKeys as $key) {
            $listing = Listing::fromKey($key);

            foreach ($periods[$key] as $period) {
                $heldCodes = $period->codes->sorted();

                // One identity claim PER PERIOD. A code that was attached and later removed keeps
                // an interval saying so, instead of silently never having existed.
                $identity[] = [
                    'kind' => 'identity',
                    'source' => $listing->source,
                    'ref' => $listing->ref(),
                    'codes' => array_map(strval(...), $heldCodes),
                    'valid_from' => $period->from,
                    'valid_to' => $period->to,
                    'recorded_at' => $period->from,
                ];

                // Grouping tracks the same periods. Dating it at the end of the fold left a window
                // where a code existed but belonged to no legacy product.
                foreach ($heldCodes as $code) {
                    $grouping[] = [
                        'kind' => 'grouping',
                        'source' => $listing->source,
                        'code' => (string) $code,
                        'product' => $listing->entity,
                        'valid_from' => $period->from,
                        'valid_to' => $period->to,
                        'recorded_at' => $period->from,
                    ];
                }
            }
        }

        $attribute = [];
        foreach ($this->envelopes as $env) {
            foreach ($env->events as $ev) {
                if ($ev->kind !== 'attribute') {
                    continue;
                }
                foreach ($this->codesAtMemoized($env->legacyEntity, $ev->source, $ev->recordedAt) as $code) {
                    $attribute[] = [
                        'kind' => 'attribute',
                        'source' => $ev->source,
                        'code' => (string) $code,
                        'field' => self::fieldDim($ev),
                        'value' => self::attributeValue($ev->data->field, $ev->data->value),
                        'valid_from' => $ev->validFrom,
                        'recorded_at' => $ev->recordedAt,
                    ];
                }
            }
        }

        $memberOf = [];
        foreach ($this->envelopes as $env) {
            foreach ($env->events as $ev) {
                if ($ev->kind !== 'edge') {
                    continue;
                }
                if (!in_array($ev->op, ['set', 'add'], true)) {
                    continue;
                }
                if ($ev->data->value === null) {
                    continue;
                }
                if (isset(self::LANE_COLLECTIONS[$ev->data->collection])) {
                    continue;
                }
                foreach ($this->codesAtMemoized($env->legacyEntity, $ev->source, $ev->recordedAt) as $code) {
                    $memberOf[] = [
                        'kind' => 'member_of',
                        'source' => $ev->source,
                        'code' => (string) $code,
                        'collection' => $ev->data->collection,
                        'member' => Stringify::value($ev->data->value),
                        'valid_from' => $ev->validFrom,
                        'recorded_at' => $ev->recordedAt,
                    ];
                }
            }
        }

        return array_merge($identity, $grouping, $attribute, $memberOf, $this->laneEntities());
    }

    /**
     * First-class lane records (media + descriptions + leaflets): fold per (listing, collection),
     * emit an identity claim in the entity's lane + a typed edge back to every code the entity
     * held at that instant.
     *
     * @return list<array<string,mixed>>
     */
    private function laneEntities(): array
    {
        $refs = self::laneRefs($this->envelopes);

        $keys = array_keys($refs);
        sort($keys, SORT_STRING);

        $out = [];
        foreach ($keys as $key) {
            $ref = $refs[$key];
            [$scheme, $lane, $relation] = self::LANE_COLLECTIONS[$ref['collection']];

            $ids = array_keys($ref['ids']);
            sort($ids, SORT_STRING);
            foreach ($ids as $id) {
                [$vf, $at] = $ref['last'][$id];

                // The lane entity exists whether or not it currently reaches a product; an asset
                // with no live edge is orphaned, not deleted.
                $out[] = [
                    'kind' => 'identity',
                    'source' => $ref['source'],
                    'ref' => $ref['collection'].':'.$id,
                    'codes' => [$scheme.':'.$id],
                    'entity' => $lane,
                    'valid_from' => $vf ?? $at,
                    'recorded_at' => $at,
                ];

                // Media events are entity-scoped (source: nil in real dumps), so one edge per
                // product code the entity held then — the same image reaches every product it was
                // listed against.
                foreach ($this->codesAtMemoized($ref['entity'], null, $at) as $code) {
                    $out[] = [
                        'kind' => 'edge',
                        'source' => $ref['source'],
                        'from' => $scheme.':'.$id,
                        'relation' => $relation,
                        'to' => (string) $code,
                        'valid_from' => $vf ?? $at,
                        'recorded_at' => $at,
                    ];
                }
            }
        }

        return $out;
    }

    /**
     * Fold media events per (listing-or-source_system, collection): add/remove churn on the asset
     * id, so only surviving references remain.
     *
     * @param list<Envelope> $envelopes
     * @return array<string, array{ids: array<string,true>, last: array<string, array{0: mixed, 1: mixed}>, entity: mixed, source: string, collection: string}>
     */
    private static function laneRefs(array $envelopes): array
    {
        $acc = [];
        foreach ($envelopes as $env) {
            foreach ($env->events as $ev) {
                if ($ev->kind !== 'media') {
                    continue;
                }
                if (!isset(self::LANE_COLLECTIONS[$ev->data->collection])) {
                    continue;
                }
                $listing = new Listing($env->legacyEntity, $ev->source ?? $env->sourceSystem);
                $key = $listing->key()."\x1f".$ev->data->collection;
                $id = Stringify::value($ev->data->asset);

                if (!isset($acc[$key])) {
                    $acc[$key] = [
                        'ids' => [],
                        'last' => [],
                        'entity' => $listing->entity,
                        'source' => $listing->source,
                        'collection' => $ev->data->collection,
                    ];
                }
                if ($ev->op === 'remove') {
                    unset($acc[$key]['ids'][$id]);
                } else {
                    $acc[$key]['ids'][$id] = true;
                }
                $acc[$key]['last'][$id] = [$ev->validFrom, $ev->recordedAt];
            }
        }

        return $acc;
    }

    // ── the per-listing fold ─────────────────────────────────────────────────────

    /**
     * Per-listing code-set `Period`s — mirrors ClaimMapping.listing_periods/1.
     *
     * A final-state fold answers "which codes does this listing carry now" and throws the history
     * away. That is wrong for any code that can move: a barcode transferred to another pack leaves
     * no trace it was ever here. This replays the same events but snapshots the code set after
     * each one, coalescing runs where the set did not change.
     *
     * @param list<Envelope> $envelopes
     * @return array<string, list<Period>>
     */
    public static function listingPeriods(array $envelopes): array
    {
        $raw = [];
        $periods = [];
        $canon = []; // memo: canonicalizing a code preg_matches — the same codes recur every event

        foreach ($envelopes as $env) {
            foreach ($env->events as $ev) {
                if ($ev->kind !== 'identity') {
                    continue;
                }

                $key = (new Listing($env->legacyEntity, $ev->source))->key();
                $raw[$key] = self::applyIdentity($raw[$key] ?? [], $ev);
                $periods[$key] = self::appendPeriod(
                    $periods[$key] ?? [],
                    self::engineCodes($raw[$key], $canon),
                    $ev->recordedAt,
                );
            }
        }

        return $periods;
    }

    /**
     * @param list<Period> $periods chronological; the last one is still open
     * @return list<Period>
     */
    private static function appendPeriod(array $periods, CodeSet $codes, int $at): array
    {
        if ($periods === []) {
            return [new Period($at, null, $codes)];
        }

        $current = $periods[count($periods) - 1];

        // The set did not change — the current period simply continues.
        if ($current->codes->equals($codes)) {
            return $periods;
        }

        // Same UTC day: replace rather than leave an interval that can never apply — every reader
        // works at day granularity, and the live wire rejects a same-day interval anyway.
        if ($current->openedSameUtcDayAs($at)) {
            $periods[count($periods) - 1] = $current->withCodes($codes);

            return $periods;
        }

        $periods[count($periods) - 1] = $current->closedAt($at);
        $periods[] = new Period($at, null, $codes);

        return $periods;
    }

    /**
     * The identifiers a claim is about, as of the instant it was made — mirrors codes_at/4.
     *
     * A SOURCED event is about the codes that source itself held then — or, when it held none at
     * that instant but did identify this listing at some point, the nearest codes it held (gr-4iu).
     * An UNSOURCED event is scoped to the legacy entity, and the entity id is an identifier in its
     * own right (that is what grouping claims make first-class), so it is about every code the
     * entity carried then, across listings.
     *
     * @param array<string, list<Period>> $periods
     * @return list<Code> deterministically ordered
     */
    public static function codesAt(array $periods, mixed $entity, ?string $source, int $at): array
    {
        if ($source !== null) {
            $listingPeriods = $periods[(new Listing($entity, $source))->key()] ?? [];
            $codes = self::codesCovering($listingPeriods, $at);
            if ($codes->isEmpty()) {
                // gr-4iu: the source DID identify this listing but spoke outside its held window.
                $codes = self::nearestCodes($listingPeriods, $at);
            }

            return $codes->sorted();
        }

        $union = CodeSet::none();
        foreach ($periods as $key => $listingPeriods) {
            if (!Listing::fromKey($key)->isFor($entity)) {
                continue;
            }
            $union = $union->union(self::codesCovering($listingPeriods, $at));
        }

        return $union->sorted();
    }

    /**
     * The codes the covering period holds — with the gr-gh0 exception: periods are half-open, so
     * the period OPENING at an instant owns it, which is right for identity but wrong for an
     * attribute stated in the same batch as a delisting. At the exact instant a source delists,
     * anchor to the codes the CLOSING period held. Mirrors codes_covering/2.
     *
     * @param list<Period> $periods
     */
    private static function codesCovering(array $periods, int $at): CodeSet
    {
        foreach ($periods as $period) {
            if (!$period->covers($at)) {
                continue;
            }
            if ($period->isDelisting() && $period->opensAt($at)) {
                foreach ($periods as $closing) {
                    if ($closing->closesAt($at)) {
                        return $closing->codes;
                    }
                }

                return CodeSet::none();
            }

            return $period->codes;
        }

        return CodeSet::none();
    }

    /**
     * gr-4iu: a source that spoke outside the window it held codes anchors to the codes it held
     * nearest in the past (bridging a delisting gap), or — before it first identified — to the
     * earliest codes it ever asserted on this listing. A source that never asserted a code still
     * anchors to nothing and the event is refused. Mirrors nearest_codes/2 (periods are
     * chronological, so a forward scan is the take_while).
     *
     * @param list<Period> $periods
     */
    private static function nearestCodes(array $periods, int $at): CodeSet
    {
        $held = array_values(array_filter($periods, static fn (Period $p): bool => !$p->isDelisting()));

        $past = null;
        foreach ($held as $period) {
            if ($period->from > $at) {
                break;
            }
            $past = $period;
        }
        if ($past !== null) {
            return $past->codes;
        }

        return $held === [] ? CodeSet::none() : $held[0]->codes;
    }

    /**
     * Events that cannot become claims, with the reason — mirrors rejected/1.
     *
     * A claim is about one or more identifiers. An event whose source held no code when it spoke
     * has nothing to be about, so it is refused rather than dropped quietly.
     *
     * @param list<Envelope> $envelopes
     * @return list<array<string,mixed>>
     */
    public static function rejected(array $envelopes): array
    {
        return (new self($envelopes))->rejectedClaims();
    }

    /** @return list<array<string,mixed>> */
    private function rejectedClaims(): array
    {
        $out = [];
        foreach ($this->envelopes as $env) {
            foreach ($env->events as $ev) {
                if (!in_array($ev->kind, ['attribute', 'edge'], true)) {
                    continue;
                }
                if ($this->codesAtMemoized($env->legacyEntity, $ev->source, $ev->recordedAt) !== []) {
                    continue;
                }
                $out[] = [
                    'entity' => $env->legacyEntity,
                    'source' => $ev->source,
                    'kind' => $ev->kind,
                    'detail' => $ev->kind === 'attribute' ? self::fieldDim($ev) : $ev->data->collection,
                    'recorded_at' => $ev->recordedAt,
                    'reason' => $ev->source === null ? 'unsourced' : 'source_held_no_code',
                ];
            }
        }

        return $out;
    }

    /**
     * The final (current) code-set per listing, delisted (now-empty) listings dropped. The last
     * period of each listing IS the final fold state — its codes were computed fresh at the last
     * set-changing event, and only set-preserving ops can follow — so no extra replay is needed.
     *
     * @param array<string, list<Period>> $periods
     * @return array<string, CodeSet>
     */
    private static function finalCodes(array $periods): array
    {
        $out = [];
        foreach ($periods as $key => $list) {
            $codes = $list[count($list) - 1]->codes;
            if (!$codes->isEmpty()) {
                $out[$key] = $codes;
            }
        }

        return $out;
    }

    /**
     * codesAt with the build's memo — canonical and rejected ask the same (entity, source, at)
     * questions; codesAt is pure over the fold's periods, so the first answer serves both.
     * Unsourced lookups additionally go through the lazily built entity → listing-keys index:
     * the public codesAt scans every listing per call, which is O(batch²) across a multi-entity
     * backfill batch (most media events are unsourced).
     *
     * @return list<Code>
     */
    private function codesAtMemoized(mixed $entity, ?string $source, int $at): array
    {
        $key = Listing::entityTag($entity)."\x1f".($source ?? "\x00")."\x1f".$at;
        if (isset($this->codesAtMemo[$key])) {
            return $this->codesAtMemo[$key];
        }

        if ($source !== null) {
            return $this->codesAtMemo[$key] = self::codesAt($this->periods, $entity, $source, $at);
        }

        $this->entityListings ??= self::entityListings($this->periods);
        $union = CodeSet::none();
        foreach ($this->entityListings[Listing::entityTag($entity)] ?? [] as $listingKey) {
            $union = $union->union(self::codesCovering($this->periods[$listingKey], $at));
        }

        return $this->codesAtMemo[$key] = $union->sorted();
    }

    /**
     * Listing keys grouped per entity, in $periods order. Keyed by the tagged entity scalar
     * {@see Listing::isFor} distinguishes on, so the indexed union matches codesAt exactly.
     *
     * @param array<string, list<Period>> $periods
     * @return array<string, list<string>>
     */
    private static function entityListings(array $periods): array
    {
        $out = [];
        foreach (array_keys($periods) as $key) {
            $out[Listing::entityTag(Listing::fromKey($key)->entity)][] = $key;
        }

        return $out;
    }

    /**
     * Apply one identity delta (set/add/remove/delete) to a raw code-set (scheme => set-of-values).
     * Folding runs on medipim's own scheme names so eanGtin13(set) and ean(add) don't interfere;
     * `engineCodes` maps to engine schemes afterwards.
     *
     * @param array<string, array<string,true>> $raw
     * @return array<string, array<string,true>>
     */
    private static function applyIdentity(array $raw, DecodedEvent $ev): array
    {
        $scheme = $ev->data->scheme;
        $code = $ev->data->code;

        switch ($ev->op) {
            case 'set':
                if ($code === null) {
                    unset($raw[$scheme]);
                } else {
                    $raw[$scheme] = [(string) $code => true];
                }

                return $raw;
            case 'add':
                $raw[$scheme][(string) $code] = true;

                return $raw;
            case 'remove':
                if (isset($raw[$scheme])) {
                    unset($raw[$scheme][(string) $code]);
                    if ($raw[$scheme] === []) {
                        unset($raw[$scheme]);
                    }
                }

                return $raw;
            case 'delete':
                unset($raw[$scheme]);

                return $raw;
            default:
                return $raw;
        }
    }

    /**
     * raw (medipim scheme → values) → the canonicalized engine `CodeSet`.
     *
     * @param array<string, array<string,true>> $raw
     * @param array<string, Code> $canon canonical-code memo, scoped to one fold
     */
    private static function engineCodes(array $raw, array &$canon = []): CodeSet
    {
        $codes = CodeSet::none();
        foreach ($raw as $scheme => $values) {
            foreach (array_keys($values) as $value) {
                $codes = $codes->with($canon[$scheme."\x1f".$value] ??= (new Code(CodeRegistry::scheme($scheme), (string) $value))->canonical());
            }
        }

        return $codes;
    }

    /** @param array<string, CodeSet> $codesByListing */
    private static function sharedCodes(array $codesByListing): CodeSet
    {
        $shared = CodeSet::none();
        foreach ($codesByListing as $codes) {
            foreach ($codes as $code) {
                if (self::neverBridges($code)) {
                    $shared = $shared->with($code);
                }
            }
        }

        return $shared;
    }

    /**
     * May this code never bridge two products? Restricted/in-store GTINs and the non-bridging
     * schemes (supplier refs, ARTG registrations) are carried but never fuse.
     */
    public static function neverBridges(Code $code): bool
    {
        return $code->isRestricted() || in_array($code->scheme, self::NON_BRIDGING_SCHEMES, true);
    }

    /**
     * Engine-shape variant of `neverBridges` for callers still speaking `[scheme, value]` pairs.
     *
     * @param array{0: string, 1: string} $code
     */
    public static function isShared(array $code): bool
    {
        return self::neverBridges(Code::fromPair($code));
    }

    // ── attribute values ─────────────────────────────────────────────────────────

    /**
     * medipim emits allowedSpecies both as "human" and as ["human"]. A one-element list carries no
     * more information than its element, so the two spellings stop looking like a contradiction.
     * Longer lists are left alone. Mirrors attribute_value/2.
     */
    private static function attributeValue(string $field, mixed $value): mixed
    {
        if (is_array($value) && count($value) === 1 && array_is_list($value)) {
            return self::normalizeQuantity($field, $value[0]);
        }

        return self::normalizeQuantity($field, $value);
    }

    /**
     * Quantity fields with a DECLARED storage unit (gr-sx7.3): medipim stores weight in grams and
     * dimensions in millimetres; "<num>_<unit>" strings serialize the SAME fact. Declaration-driven,
     * never sniffed — an undeclared field's digits-only string passes through untouched. Mirrors
     * ClaimMapping.normalize_quantity/2.
     */
    private const QUANTITY_UNITS = [
        'weight' => ['g' => 1, 'kg' => 1000],
        'width' => ['mm' => 1, 'cm' => 10],
        'depth' => ['mm' => 1, 'cm' => 10],
        'length' => ['mm' => 1, 'cm' => 10],
    ];

    private static function normalizeQuantity(string $field, mixed $value): mixed
    {
        if (!is_string($value) || !isset(self::QUANTITY_UNITS[$field])) {
            return $value;
        }
        $parts = explode('_', $value);
        if (count($parts) !== 2 || !isset(self::QUANTITY_UNITS[$field][$parts[1]])) {
            return $value;
        }
        if (preg_match('/^\d+(\.\d+)?$/', $parts[0]) !== 1) {
            return $value;
        }
        $scaled = (float) $parts[0] * self::QUANTITY_UNITS[$field][$parts[1]];
        $rounded = (int) round($scaled);

        return abs($scaled - $rounded) < 1.0e-9 ? $rounded : $scaled;
    }

    public static function fieldDim(DecodedEvent $ev): string
    {
        $locale = $ev->data->locale;

        return $locale === null ? $ev->data->field : $ev->data->field.':'.$locale;
    }

    // ── ordering + scalar plumbing ──────────────────────────────────────────────

    /**
     * Chronological order stamp: later recorded_at ⇒ higher order; stable on emission index.
     *
     * @param list<Claim> $claims
     * @return list<Claim>
     */
    private static function stamp(array $claims): array
    {
        if ($claims === []) {
            return [];
        }

        // Column sort instead of usort: the comparator allocated two tuples per comparison.
        // The emission-index column makes it stable, same order as [numeric, i] <=> [numeric, i].
        $at = [];
        $idx = [];
        foreach ($claims as $i => $c) {
            $at[] = self::numeric($c->recordedAt);
            $idx[] = $i;
        }
        array_multisort($at, SORT_ASC, SORT_REGULAR, $idx, SORT_ASC, SORT_NUMERIC, $claims);

        $out = [];
        foreach ($claims as $order => $c) {
            $out[] = $c->withOrder($order);
        }

        return $out;
    }

    private static function numeric(mixed $v): int|float
    {
        return is_numeric($v) ? 0 + $v : 0;
    }

}
