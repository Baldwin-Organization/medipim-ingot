<?php

declare(strict_types=1);

namespace Ingot\Tests;

use Ingot\ClaimMapping;
use Ingot\EnvelopeDecoder;
use Ingot\EnvelopeLoader;
use PHPUnit\Framework\Attributes\DataProvider;
use PHPUnit\Framework\TestCase;

/**
 * Parity gate for the runtime decoder: decoding the real `.raw.jsonl` dumps must reproduce the
 * committed `.json` envelopes the Elixir oracle (gen.exs) emitted — proving the PHP decoder applies
 * medipim's decode rules identically. Then a decode -> loader -> ClaimMapping smoke check.
 */
final class EnvelopeDecoderTest extends TestCase
{
    private const FIXTURES = __DIR__.'/../../test/ingest/fixtures/';

    /** @return iterable<string, array{0: string, 1: int}> */
    public static function fixtures(): iterable
    {
        yield 'medipim-be 422156' => ['medipim-be', 422156];
        yield 'medipim-fr 347025' => ['medipim-fr', 347025];
    }

    #[DataProvider('fixtures')]
    public function test_decode_reproduces_the_committed_envelope(string $source, int $entity): void
    {
        $slug = str_replace('-', '_', $source).'_'.$entity;
        $raw = file_get_contents(self::FIXTURES.$slug.'.raw.jsonl');
        $expected = json_decode(file_get_contents(self::FIXTURES.$slug.'.json'), true, 512, JSON_THROW_ON_ERROR);

        $decoded = EnvelopeDecoder::decodeJsonl($raw, $source, $entity);

        self::assertSame(self::canonical($expected), self::canonical($decoded));
    }

    public function test_decoded_envelope_loads_and_maps_to_claims(): void
    {
        $raw = file_get_contents(self::FIXTURES.'medipim_be_422156.raw.jsonl');
        $decoded = EnvelopeDecoder::decodeJsonl($raw, 'medipim-be', 422156);

        [$ok, $env] = EnvelopeLoader::fromMap($decoded);
        self::assertSame('ok', $ok);
        self::assertSame(
            ['identity' => 23, 'attribute' => 127, 'edge' => 12, 'media' => 768],
            self::orderedCounts(EnvelopeLoader::kindCounts($env))
        );

        $built = ClaimMapping::build([$env]);
        self::assertNotEmpty($built['claims']);
        foreach ($built['claims'] as $claim) {
            self::assertInstanceOf(\Ingot\Claim::class, $claim);
            self::assertNotNull($claim->order);
        }
    }

    public function test_identity_scheme_injects_a_lane_record_for_a_non_product_entity(): void
    {
        // A descriptions_deltas-shaped history carries no identity code; the entity IS the identity.
        $deltas = [
            ['created_at' => 1000, 'created_by' => 7, 'tag' => 'd1', 'events' => [
                ['1', 'title:nl', 'Bijsluiter'],
                ['1', 'updatedAt', 1000],
            ]],
        ];

        $decoded = EnvelopeDecoder::decode($deltas, 'medipim-be', 9001, ['identity_scheme' => 'text_id']);

        self::assertSame('identity', $decoded['events'][0]['kind']);
        self::assertSame('text_id', $decoded['events'][0]['scheme']);
        self::assertSame('9001', $decoded['events'][0]['code']);

        [$ok, $env] = EnvelopeLoader::fromMap($decoded);
        self::assertSame('ok', $ok);
        $built = ClaimMapping::build([$env]);
        self::assertNotEmpty($built['claims']);
    }

    /** Recursively key-sort assoc maps (key-order-insensitive) while preserving list order + types. */
    private static function canonical(mixed $v): string
    {
        return json_encode(self::sortKeys($v), JSON_THROW_ON_ERROR);
    }

    private static function sortKeys(mixed $v): mixed
    {
        if (!is_array($v)) {
            return $v;
        }
        $out = [];
        foreach ($v as $k => $child) {
            $out[$k] = self::sortKeys($child);
        }
        if (!array_is_list($out)) {
            ksort($out);
        }

        return $out;
    }

    /** @param array<string,int> $a @return array<string,int> */
    private static function orderedCounts(array $a): array
    {
        return ['identity' => $a['identity'], 'attribute' => $a['attribute'], 'edge' => $a['edge'], 'media' => $a['media']];
    }
}
