<?php

declare(strict_types=1);

namespace Ingot\Tests;

use Ingot\EnvelopeLoader;
use PHPUnit\Framework\TestCase;

/**
 * Ported from test/ingest/envelope_loader_test.exs: the real 422156 fixture happy path + the
 * validation failure modes (as ['error', reason] tuples).
 */
final class EnvelopeLoaderTest extends TestCase
{
    private const FIXTURE = __DIR__.'/../../test/ingest/fixtures/medipim_be_422156.json';

    public function test_envelope_level_fields(): void
    {
        [$ok, $env] = EnvelopeLoader::load(self::FIXTURE);
        self::assertSame('ok', $ok);
        self::assertSame('1', $env->schemaVersion);
        self::assertSame('medipim-be', $env->sourceSystem);
        self::assertSame(422156, $env->legacyEntity);
        self::assertSame(1778976623, $env->lastTouchedAt);
        self::assertSame(819, $env->droppedMetaCount);
        self::assertCount(930, $env->events);
    }

    public function test_kind_counts(): void
    {
        $env = EnvelopeLoader::loadBang(self::FIXTURE);
        self::assertSame(
            ['identity' => 23, 'attribute' => 127, 'edge' => 12, 'media' => 768],
            self::sortByKey(EnvelopeLoader::kindCounts($env))
        );
    }

    public function test_order_is_zero_to_n_minus_one(): void
    {
        $env = EnvelopeLoader::loadBang(self::FIXTURE);
        self::assertSame(range(0, 929), array_map(static fn (\Ingot\DecodedEvent $e): int => $e->order, $env->events));
    }

    public function test_first_identity_event(): void
    {
        $env = EnvelopeLoader::loadBang(self::FIXTURE);
        $first = null;
        foreach ($env->events as $e) {
            if ($e->kind === 'identity') {
                $first = $e;
                break;
            }
        }
        self::assertSame('set', $first->op);
        self::assertSame('1034', $first->source);
        self::assertSame(1535726805, $first->recordedAt);
        self::assertSame(['scheme' => 'cnk', 'code' => '3612173'], $first->data->toArray());
    }

    public function test_validation_failures(): void
    {
        self::assertSame(['error', ['unsupported_schema_version', '9']], EnvelopeLoader::fromMap(['schema_version' => '9', 'events' => []]));
        self::assertSame(['error', 'missing_events'], EnvelopeLoader::fromMap(['schema_version' => '1']));
        self::assertSame(['error', 'events_not_a_list'], EnvelopeLoader::fromMap(['schema_version' => '1', 'events' => 'nope']));
        self::assertSame(['error', 'not_an_object'], EnvelopeLoader::fromMap('nope'));

        $envWith = static fn (array $event): array => ['schema_version' => '1', 'events' => [$event]];
        self::assertSame(['error', ['event', 0, ['unknown_op', 'frob']]], EnvelopeLoader::fromMap($envWith(['op' => 'frob', 'kind' => 'identity', 'scheme' => 'cnk'])));
        self::assertSame(['error', ['event', 0, ['unknown_kind', 'nonsense']]], EnvelopeLoader::fromMap($envWith(['op' => 'set', 'kind' => 'nonsense'])));
        self::assertSame(['error', ['event', 0, ['missing_keys', ['scheme']]]], EnvelopeLoader::fromMap($envWith(['op' => 'set', 'kind' => 'identity', 'code' => '1'])));
    }

    public function test_valid_from_defaults_to_recorded_at(): void
    {
        [$ok, $env] = EnvelopeLoader::fromMap(['schema_version' => '1', 'events' => [['op' => 'set', 'kind' => 'identity', 'scheme' => 'cnk', 'code' => '1', 'recorded_at' => 123]]]);
        self::assertSame('ok', $ok);
        self::assertSame(123, $env->events[0]->validFrom);
    }

    private static function sortByKey(array $a): array
    {
        // present in a stable order for the assertSame above (assoc compare is order-insensitive
        // only via ==, so reorder to the expected layout).
        return ['identity' => $a['identity'], 'attribute' => $a['attribute'], 'edge' => $a['edge'], 'media' => $a['media']];
    }
}
