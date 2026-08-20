<?php

declare(strict_types=1);

namespace Ingot\Tests;

use Ingot\Api;
use Ingot\DimensionAliases;
use Ingot\EnvelopeLoader;
use Ingot\GoldenRecords;
use Ingot\Substrate;
use PHPUnit\Framework\TestCase;

/**
 * The dimension-alias seam (GH #129): an injected old→new field-name map applied where claims are
 * normalized on the way in, so a source-side field rename folds as ONE dimension. The Elixir port
 * pins the same scenarios (test/dimension_aliases_test.exs) so parity guards the remap semantics.
 */
final class DimensionAliasesTest extends TestCase
{
    // ── resolve ─────────────────────────────────────────────────────────────

    public function test_a_name_not_in_the_map_passes_through(): void
    {
        self::assertSame('c', DimensionAliases::resolve(['a' => 'b'], 'c'));
        self::assertSame('a', DimensionAliases::resolve([], 'a'));
    }

    public function test_chains_resolve_transitively_to_the_terminal_name(): void
    {
        $aliases = ['a' => 'b', 'b' => 'c'];
        self::assertSame('c', DimensionAliases::resolve($aliases, 'a'));
        self::assertSame('c', DimensionAliases::resolve($aliases, 'b'));
    }

    public function test_a_cycle_terminates_instead_of_looping(): void
    {
        self::assertContains(DimensionAliases::resolve(['a' => 'b', 'b' => 'a'], 'a'), ['a', 'b']);
    }

    public function test_a_locale_suffix_rides_along_on_the_aliased_field_part(): void
    {
        self::assertSame('title:fr', DimensionAliases::resolve(['name' => 'title'], 'name:fr'));
    }

    public function test_an_exact_whole_name_entry_wins_over_the_bare_field_entry(): void
    {
        $aliases = ['name' => 'title', 'name:fr' => 'frenchTitle'];
        self::assertSame('frenchTitle', DimensionAliases::resolve($aliases, 'name:fr'));
        self::assertSame('title:nl', DimensionAliases::resolve($aliases, 'name:nl'));
    }

    // ── normalize over engine claims ────────────────────────────────────────

    private function attr(string $field, string $value, int $order): \Ingot\Claim
    {
        $c = Substrate::claim('A', 'attribute', ['code' => ['cnk', '1234567'], 'field' => $field, 'value' => $value], $order, $order);

        return $c->withOrder($order);
    }

    public function test_an_attribute_claims_field_is_rewritten_to_the_terminal_alias(): void
    {
        [$normalized] = DimensionAliases::normalize([$this->attr('name', 'x', 1)], ['name' => 'title']);
        self::assertSame('title', $normalized->data['field']);
    }

    public function test_a_member_of_edges_collection_name_is_rewritten_the_member_is_not(): void
    {
        $memberOf = Substrate::claim('A', 'member_of', ['member_code' => ['cnk', '1234567'], 'collection' => ['brands', '42']], 1, 1);
        [$normalized] = DimensionAliases::normalize([$memberOf], ['brands' => 'makers']);

        self::assertSame('edge', $normalized->kind);
        self::assertSame(['makers', '42'], $normalized->data['to']);
        self::assertSame(['cnk', '1234567'], $normalized->data['from']);
    }

    public function test_identity_claims_are_untouched_schemes_are_not_field_names(): void
    {
        $identity = Substrate::claim('A', 'identity', ['ref' => '1:A', 'codes' => [['cnk', '1234567']]], 1, 1);
        self::assertSame([$identity], DimensionAliases::normalize([$identity], ['cnk' => 'nope']));
    }

    public function test_both_spellings_of_a_renamed_field_collapse_to_one_slot_later_order_wins(): void
    {
        $claims = [$this->attr('name', 'Old', 1), $this->attr('title', 'New', 2)];
        $current = Substrate::current(DimensionAliases::normalize($claims, ['name' => 'title']));

        self::assertCount(1, $current);
        self::assertSame('title', $current[0]->data['field']);
        self::assertSame('New', $current[0]->data['value']);
    }

    // ── the seam threads through the projection entry ───────────────────────

    private function renameEnvelope(): \Ingot\Envelope
    {
        [$ok, $env] = EnvelopeLoader::fromMap([
            'schema_version' => '1',
            'legacy_entity' => 1,
            'events' => [
                ['recorded_at' => 10, 'source' => 'A', 'op' => 'set', 'kind' => 'identity', 'scheme' => 'cnk', 'code' => '1234567'],
                ['recorded_at' => 10, 'source' => 'A', 'op' => 'set', 'kind' => 'attribute', 'field' => 'name', 'value' => 'Old'],
                ['recorded_at' => 20, 'source' => 'A', 'op' => 'set', 'kind' => 'attribute', 'field' => 'title', 'value' => 'New'],
            ],
        ]);
        self::assertSame('ok', $ok);

        return $env;
    }

    public function test_without_aliases_a_rename_splits_the_dimension(): void
    {
        $variant = GoldenRecords::fromEnvelopes([$this->renameEnvelope()], 100)['records'][0]->variants[0];

        $fields = array_map(static fn (array $pair): string => $pair[0], $variant->attributes);
        sort($fields);
        self::assertSame(['name', 'title'], $fields);
    }

    public function test_with_aliases_the_rename_folds_as_one_dimension(): void
    {
        $variant = GoldenRecords::fromEnvelopes([$this->renameEnvelope()], 100, null, ['name' => 'title'])['records'][0]->variants[0];

        self::assertCount(1, $variant->attributes);
        [$field, $decision] = $variant->attributes[0];
        self::assertSame('title', $field);
        self::assertSame('New', $decision->value);
    }

    public function test_the_engine_read_layer_over_the_projected_log_agrees_with_the_projection(): void
    {
        // gr-1y5: the projection returns the alias-normalized log, so Api::get over that log
        // folds the SAME dimension — the stale spelling must not survive in a second slot.
        $log = GoldenRecords::fromEnvelopes([$this->renameEnvelope()], 100, null, ['name' => 'title'])['log'];

        $priority = GoldenRecords::defaultPriority();
        $key = Api::resolveKey($log, ['cnk', '1234567']);
        $variant = Api::get($log, $key, $priority)['variant'];

        self::assertCount(1, $variant->attributes);
        [$field, $decision] = $variant->attributes[0];
        self::assertSame('title', $field);
        self::assertSame('New', $decision->value);
    }
}
