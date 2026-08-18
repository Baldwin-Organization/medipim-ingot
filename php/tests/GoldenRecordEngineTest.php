<?php

declare(strict_types=1);

namespace Ingot\Tests;

use Ingot\Canonical422156;
use Ingot\EnvelopeLoader;
use Ingot\GoldenRecordEngine;
use PHPUnit\Framework\TestCase;

/**
 * The facade must produce exactly what the hand-wired five-module path produces. We reuse the
 * 422156 parity gate: the engine's `toJson()` must equal the canonical-encoded Elixir oracle output,
 * and the read-side queries must work off the same log.
 */
final class GoldenRecordEngineTest extends TestCase
{
    private const FIXTURE = __DIR__.'/../../test/ingest/fixtures/medipim_be_422156.json';
    private const EXPECTED = __DIR__.'/../bench/golden_422156.expected.json';

    public function test_ingestFile_matches_the_canonical_oracle(): void
    {
        $result = (new GoldenRecordEngine())->ingestFile(self::FIXTURE, 1);

        $expectedDecoded = json_decode(file_get_contents(self::EXPECTED), true, 512, JSON_THROW_ON_ERROR);
        self::assertSame(Canonical422156::encode($expectedDecoded), $result->toJson());
    }

    public function test_ingest_envelopes_equals_ingestFile(): void
    {
        $engine = new GoldenRecordEngine();
        $env = EnvelopeLoader::loadBang(self::FIXTURE);

        self::assertSame(
            $engine->ingestFile(self::FIXTURE, 1)->toJson(),
            $engine->ingest([$env], 1)->toJson(),
        );
    }

    public function test_result_exposes_records_and_read_side(): void
    {
        $result = (new GoldenRecordEngine())->ingestFile(self::FIXTURE, 1);

        self::assertCount(1, $result->records());
        self::assertSame(422156, $result->records()[0]->product);

        // identity-aware code lookup: the CNK resolves to the owning surrogate key.
        $key = $result->resolve(['cnk', '3612173']);
        self::assertNotNull($key);
        self::assertSame(['status' => 'active'], $result->identityStatus($key)->toArray());

        // the change feed sees the minting identity events.
        self::assertNotEmpty($result->changesSince(0));
    }
}
