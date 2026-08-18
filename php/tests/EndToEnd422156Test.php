<?php

declare(strict_types=1);

namespace Ingot\Tests;

use Ingot\Canonical422156;
use Ingot\EnvelopeLoader;
use Ingot\GoldenRecords;
use Ingot\LegacyXref;
use Ingot\MigrationDiff;
use Ingot\Rederivation;
use PHPUnit\Framework\TestCase;

/**
 * THE correctness gate. Folds the real medipim-422156 fixture through the ported PHP modules,
 * projects to the SAME canonical document the Elixir oracle (php/bench/dump_golden_422156.exs)
 * emits, recursively sorts keys, and asserts byte-equality with golden_422156.expected.json.
 *
 * The expected file is the Elixir engine's output (its JSON.encode!). To compare structure rather
 * than encoder quirks, BOTH sides are re-encoded through the one PHP canonical encoder: the expected
 * JSON is decoded and re-encoded identically, so a byte difference is a real projection difference.
 */
final class EndToEnd422156Test extends TestCase
{
    private const FIXTURE = __DIR__.'/../../test/ingest/fixtures/medipim_be_422156.json';
    private const EXPECTED = __DIR__.'/../bench/golden_422156.expected.json';

    public function test_php_fold_matches_the_elixir_golden_record_byte_for_byte(): void
    {
        $env = EnvelopeLoader::loadBang(self::FIXTURE);
        $at = 1;

        $gr = GoldenRecords::fromEnvelopes([$env], $at);
        $xref = LegacyXref::fromEnvelopes([$env], $at);
        $diff = MigrationDiff::fromEnvelopes([$env], $at);

        $document = Canonical422156::document($gr, $xref, $diff);
        $actual = Canonical422156::encode($document);

        self::assertFileExists(self::EXPECTED, 'run `mix run php/bench/dump_golden_422156.exs` first');
        $expectedDecoded = json_decode(file_get_contents(self::EXPECTED), true, 512, JSON_THROW_ON_ERROR);
        $expected = Canonical422156::encode($expectedDecoded);

        self::assertSame($expected, $actual, 'PHP golden record diverged from the Elixir oracle');
    }

    public function test_the_fold_is_one_product_one_variant_keyed_sk1(): void
    {
        $env = EnvelopeLoader::loadBang(self::FIXTURE);
        $gr = GoldenRecords::fromEnvelopes([$env], 1);

        self::assertCount(1, $gr['records']);
        self::assertSame(422156, $gr['records'][0]->product);
        self::assertCount(1, $gr['records'][0]->variants);
        self::assertSame('SK_1', $gr['records'][0]->variants[0]->key);
    }

    public function test_rederivation_converges_to_one_key(): void
    {
        $env = EnvelopeLoader::loadBang(self::FIXTURE);
        $result = Rederivation::run([$env], 1);

        self::assertCount(1, $result['clusters']);
        $product = \Ingot\Lanes::partitionMembers($result['ledger']->members)['product'];
        self::assertSame(['SK_1'], array_keys($product));
        self::assertTrue(\Ingot\Sets::member($product['SK_1'], ['cnk', '3612173']));
    }
}
