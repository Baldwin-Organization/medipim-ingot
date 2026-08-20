<?php

declare(strict_types=1);

namespace Ingot\Tests;

use Ingot\ClaimMapping;
use Ingot\Cluster;
use Ingot\EnvelopeLoader;
use Ingot\Lanes;
use Ingot\Sets;
use Ingot\Substrate;
use PHPUnit\Framework\TestCase;

/**
 * Ported from test/ingest/claim_mapping_test.exs: the fold semantics (set/add/remove/delete/clear),
 * canonicalize+partition (shared set), claim shapes, and the real 422156 convergence.
 */
final class ClaimMappingTest extends TestCase
{
    private const FIXTURE = __DIR__.'/../../test/ingest/fixtures/medipim_be_422156.json';

    private function envelope(int $entity, array $events): \Ingot\Envelope
    {
        [$ok, $env] = EnvelopeLoader::fromMap(['schema_version' => '1', 'legacy_entity' => $entity, 'events' => $events]);
        self::assertSame('ok', $ok);

        return $env;
    }

    private function id(string $source, string $op, string $scheme, ?string $code, int $at): array
    {
        return ['recorded_at' => $at, 'source' => $source, 'op' => $op, 'kind' => 'identity', 'scheme' => $scheme, 'code' => $code];
    }

    /** @return list<array{0: string, 1: string}> the listing's codes, sorted */
    private function listingCodes(array $envelopes, int $entity, string $source): array
    {
        $listings = ClaimMapping::listings($envelopes);
        $key = "i:$entity\x1f$source";

        return isset($listings[$key]) ? Sets::valuesSorted($listings[$key]) : [];
    }

    public function test_set_replaces_a_single_valued_scheme(): void
    {
        $env = $this->envelope(1, [$this->id('A', 'set', 'cnk', '111', 10), $this->id('A', 'set', 'cnk', '222', 20)]);
        self::assertSame([['cnk', '222']], $this->listingCodes([$env], 1, 'A'));
    }

    public function test_add_accumulates_remove_deletes_one(): void
    {
        $env = $this->envelope(1, [
            $this->id('A', 'add', 'ean', '5012345678900', 10),
            $this->id('A', 'add', 'ean', '4006381333931', 20),
            $this->id('A', 'remove', 'ean', '5012345678900', 30),
        ]);
        self::assertSame([['gtin', '04006381333931']], $this->listingCodes([$env], 1, 'A'));
    }

    public function test_delete_drops_the_whole_scheme(): void
    {
        $env = $this->envelope(1, [
            $this->id('A', 'set', 'eanGtin13', '5012345678900', 10),
            $this->id('A', 'delete', 'eanGtin13', 'A', 20),
        ]);
        self::assertSame([], ClaimMapping::listings([$env]));
    }

    public function test_set_null_clears(): void
    {
        $env = $this->envelope(1, [
            $this->id('A', 'set', 'eanGtin14', '05012345678900', 10),
            $this->id('A', 'set', 'eanGtin14', null, 20),
        ]);
        self::assertSame([], ClaimMapping::listings([$env]));
    }

    public function test_unrecognised_scheme_stays_a_string(): void
    {
        $env = $this->envelope(1, [$this->id('A', 'set', 'mysteryScheme', 'XYZ', 10)]);
        self::assertSame([['mysteryScheme', 'XYZ']], $this->listingCodes([$env], 1, 'A'));
    }

    public function test_french_fields_map_to_their_schemes(): void
    {
        $env = $this->envelope(1, [
            $this->id('A', 'set', 'cipOrAcl7', '4440813', 10),
            $this->id('A', 'set', 'acl13', '3401344408137', 20),
        ]);
        self::assertSame([['acl13', '3401344408137'], ['cip_acl7', '4440813']], $this->listingCodes([$env], 1, 'A'));
    }

    public function test_restricted_gtin_lands_in_shared(): void
    {
        $env = $this->envelope(1, [$this->id('A', 'add', 'gtin', '02000000000000', 10), $this->id('A', 'set', 'cnk', '111', 20)]);
        $built = ClaimMapping::build([$env]);
        self::assertSame([['gtin', '02000000000000']], Sets::values($built['shared']));
    }

    public function test_restricted_gtin_removed_before_end_of_history_still_lands_in_shared(): void
    {
        // gr-o91: shared comes from the FULL history, so a dropped restricted code still never bridges.
        $env = $this->envelope(1, [
            $this->id('A', 'add', 'gtin', '02000000000000', 10),
            $this->id('A', 'set', 'cnk', '111', 20),
            $this->id('A', 'remove', 'gtin', '02000000000000', 3 * 86_400),
        ]);
        $built = ClaimMapping::build([$env]);
        self::assertSame([['gtin', '02000000000000']], Sets::values($built['shared']));
    }

    public function test_fr_fixture_matches_the_elixir_reference_exactly(): void
    {
        // The cross-language pin (gr-6u6): the FR fixture exercises gr-gh0 (parting-attribute
        // anchoring) and gr-4iu (nearest-codes anchoring), which the BE fixture does not. These
        // counts are the Elixir reference's output — if either port drifts, this fails.
        $raw = json_decode(file_get_contents(__DIR__.'/../../test/ingest/fixtures/medipim_fr_347025.json'), true);
        [$ok, $env] = EnvelopeLoader::fromMap($raw);
        self::assertSame('ok', $ok);

        $built = ClaimMapping::build([$env]);

        // gr-6us widened the loud channel: the two edge REMOVE events (snapshot-v1 keeps only
        // surviving members, so the removal itself cannot become a claim) report instead of vanishing.
        $rejected = array_map(
            static fn (array $r): array => [$r['reason'], $r['detail'], $r['recorded_at']],
            $built['rejected'],
        );
        self::assertSame([
            ['unsupported_edge_op', 'internationalBrands', 1753271466],
            ['unsupported_edge_op', 'organizations', 1767725928],
        ], $rejected);

        self::assertCount(215, $built['claims']);

        $byKind = [];
        foreach ($built['claims'] as $c) {
            $byKind[$c->kind] = ($byKind[$c->kind] ?? 0) + 1;
        }
        ksort($byKind);
        self::assertSame(['attribute' => 159, 'edge' => 20, 'grouping' => 22, 'identity' => 14], $byKind);
    }

    public function test_declared_quantities_normalize_to_their_storage_unit(): void
    {
        // gr-sx7.3: bare numerics are the storage unit (g/mm); "<num>_<unit>" strings normalize
        // onto them. Declaration-driven: an undeclared field's string passes through untouched.
        $day = 86_400;
        $env = $this->envelope(1, [
            $this->id('1', 'add', 'ean', '9338475000364', 1 * $day),
            ['recorded_at' => 2 * $day, 'source' => '1', 'op' => 'set', 'kind' => 'attribute', 'field' => 'depth', 'value' => 43],
            ['recorded_at' => 3 * $day, 'source' => '1', 'op' => 'set', 'kind' => 'attribute', 'field' => 'depth', 'value' => '4.3_cm'],
            ['recorded_at' => 3 * $day, 'source' => '1', 'op' => 'set', 'kind' => 'attribute', 'field' => 'weight', 'value' => '0.065_kg'],
            ['recorded_at' => 3 * $day, 'source' => '1', 'op' => 'set', 'kind' => 'attribute', 'field' => 'hsCode', 'value' => '340130'],
        ]);

        $values = [];
        foreach (ClaimMapping::canonicalClaims([$env]) as $c) {
            if ($c['kind'] === 'attribute') {
                $values[$c['field']][] = $c['value'];
            }
        }

        self::assertSame([43, 43], $values['depth']);
        self::assertSame([65], $values['weight']);
        self::assertSame(['340130'], $values['hsCode']);
    }

    public function test_artg_id_is_identity_but_shared_never_bridges(): void
    {
        // gr-sx7.1: one ARTG registration covers many pack sizes — identity code, no fuse.
        $env = $this->envelope(1, [
            $this->id('1', 'add', 'ean', '9338475000364', 10),
            $this->id('1', 'set', 'artgId', '207479', 20),
        ]);
        $built = ClaimMapping::build([$env]);
        self::assertContains(['artg_id', '207479'], Sets::values($built['shared']));
        self::assertSame('none', \Ingot\CodeRegistry::bridgeGrade('artg_id'));
    }

    public function test_bridging_codes_not_shared(): void
    {
        $env = $this->envelope(1, [$this->id('A', 'set', 'cnk', '111', 10), $this->id('A', 'add', 'gtin', '5012345678900', 20)]);
        self::assertSame([], ClaimMapping::build([$env])['shared']);
    }

    public function test_one_identity_claim_per_listing(): void
    {
        $env = $this->envelope(7, [$this->id('A', 'set', 'cnk', '111', 10), $this->id('B', 'set', 'cnk', '222', 10)]);
        $ids = array_filter(ClaimMapping::build([$env])['claims'], static fn ($c): bool => $c->kind === 'identity');
        self::assertCount(2, $ids);
        $refs = array_map(static fn ($c): string => $c->data['ref'], $ids);
        sort($refs);
        self::assertSame(['7:A', '7:B'], $refs);
    }

    public function test_listings_order_by_entity_value_not_encoded_string(): void
    {
        // gr-h07: Elixir sorts {entity, source} tuples — entity 9 before 10. String order on the
        // encoded key emitted "i:10…" first, flipping stamp()'s tie-break for equal recorded_at.
        $e9 = $this->envelope(9, [$this->id('A', 'set', 'cnk', '111', 10)]);
        $e10 = $this->envelope(10, [$this->id('A', 'set', 'cnk', '222', 10)]);

        $refs = [];
        foreach (ClaimMapping::canonicalClaims([$e10, $e9]) as $c) {
            if ($c['kind'] === 'identity') {
                $refs[] = $c['ref'];
            }
        }
        self::assertSame(['9:A', '10:A'], $refs);
    }

    public function test_unsourced_identity_event_folds_instead_of_crashing(): void
    {
        // gr-c37: Elixir keys listings on {entity, nil}; a non-nullable Listing::$source made the
        // same envelope a TypeError here.
        $env = $this->envelope(1, [
            ['recorded_at' => 10, 'op' => 'set', 'kind' => 'identity', 'scheme' => 'cnk', 'code' => '111'],
        ]);

        $identity = array_values(array_filter(ClaimMapping::canonicalClaims([$env]), static fn (array $c): bool => $c['kind'] === 'identity'));
        self::assertCount(1, $identity);
        self::assertNull($identity[0]['source']);
        self::assertSame(['cnk:111'], $identity[0]['codes']);
    }

    public function test_int_and_string_entities_with_the_same_numeral_do_not_collide(): void
    {
        // gr-c37: isFor erased the int/string distinction key() preserves — an unsourced event
        // anchored to the union of both listings; Elixir's e == entity keeps them apart.
        [$ok1, $intEnv] = EnvelopeLoader::fromMap(['schema_version' => '1', 'legacy_entity' => 422156, 'events' => [
            $this->id('A', 'set', 'cnk', '111', 10),
            ['recorded_at' => 20, 'source' => null, 'op' => 'set', 'kind' => 'attribute', 'field' => 'name', 'value' => 'int entity'],
        ]]);
        [$ok2, $strEnv] = EnvelopeLoader::fromMap(['schema_version' => '1', 'legacy_entity' => '422156', 'events' => [
            $this->id('B', 'set', 'cnk', '222', 10),
        ]]);
        self::assertSame(['ok', 'ok'], [$ok1, $ok2]);

        $anchors = [];
        foreach (ClaimMapping::canonicalClaims([$intEnv, $strEnv]) as $c) {
            if ($c['kind'] === 'attribute') {
                $anchors[] = $c['code'];
            }
        }
        self::assertSame(['cnk:111'], $anchors);
    }

    public function test_unsourced_event_anchors_only_to_its_own_entity_in_a_multi_entity_batch(): void
    {
        // gr-e1i: the unsourced path resolves listings through a per-entity index — an unsourced
        // attribute must anchor to every code ITS entity held then, and none of another entity's.
        $e1 = $this->envelope(1, [
            $this->id('A', 'set', 'cnk', '111', 10),
            ['recorded_at' => 20, 'source' => null, 'op' => 'set', 'kind' => 'attribute', 'field' => 'name', 'value' => 'one'],
        ]);
        $e2 = $this->envelope(2, [$this->id('A', 'set', 'cnk', '222', 10)]);

        $anchors = [];
        foreach (ClaimMapping::canonicalClaims([$e1, $e2]) as $c) {
            if ($c['kind'] === 'attribute') {
                $anchors[] = $c['code'];
            }
        }
        self::assertSame(['cnk:111'], $anchors);
    }

    public function test_attribute_anchored_to_primary_cnk(): void
    {
        $env = $this->envelope(1, [
            $this->id('A', 'set', 'cnk', '111', 10),
            $this->id('A', 'add', 'gtin', '5012345678900', 10),
            ['recorded_at' => 20, 'source' => 'A', 'op' => 'set', 'kind' => 'attribute', 'field' => 'name', 'locale' => 'fr', 'value' => 'Crème'],
        ]);
        $attr = null;
        foreach (ClaimMapping::build([$env])['claims'] as $c) {
            if ($c->kind === 'attribute') {
                $attr = $c;
                break;
            }
        }
        self::assertSame(['cnk', '111'], $attr->data['code']);
        self::assertSame('name:fr', $attr->data['field']);
        self::assertSame('Crème', $attr->data['value']);
    }

    // ── the real 422156 fixture ──────────────────────────────────────────────────

    public function test_org_44_converged_dropped_old_ean(): void
    {
        $env = EnvelopeLoader::loadBang(self::FIXTURE);
        $codes = $this->listingCodes([$env], 422156, '44');
        self::assertContains(['cnk', '3612173'], $codes);
        self::assertContains(['gtin', '03282770146004'], $codes);
        self::assertNotContains(['gtin', '03282770049374'], $codes);
    }

    public function test_all_listings_collapse_to_one_key(): void
    {
        $env = EnvelopeLoader::loadBang(self::FIXTURE);
        $result = ClaimMapping::build([$env]);
        self::assertSame([], $result['shared']);

        $clusters = Cluster::variants(Lanes::identityClaims(Substrate::current($result['claims']), 'product'), $result['shared']);
        self::assertCount(1, $clusters);
        self::assertTrue(Sets::member($clusters[0], ['cnk', '3612173']));
        self::assertTrue(Sets::member($clusters[0], ['gtin', '03282770146004']));
        self::assertTrue(Sets::member($clusters[0], ['gtin', '03282770114577']));
    }
}
