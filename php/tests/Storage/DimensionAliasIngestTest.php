<?php

declare(strict_types=1);

namespace Ingot\Tests\Storage;

use Ingot\Storage\ClaimIngest;
use Ingot\Storage\InMemoryClaimStore;
use Ingot\Storage\StoreProjection;
use PHPUnit\Framework\TestCase;

/**
 * The dimension-alias seam through the persistent writer (GH #129): stored claims keep their
 * historical spelling in `{prefix}events`, but every compare/group point normalizes through the
 * injected map — so a rename never splits survivorship, never re-ingests the catalog, and
 * snapshots self-heal to the terminal names key-by-key as they are rewritten.
 */
final class DimensionAliasIngestTest extends TestCase
{
    private const ALIASES = ['name' => 'title'];

    /** @return array<string,mixed> the raw contract-C map, one identity + the given attribute events */
    private function rawMap(array $attributeEvents): array
    {
        return [
            'schema_version' => '1',
            'source_system' => 'medipim-be',
            'legacy_entity' => 1,
            'events' => array_merge(
                [['recorded_at' => 10, 'source' => 'A', 'op' => 'set', 'kind' => 'identity', 'scheme' => 'cnk', 'code' => '1234567']],
                $attributeEvents,
            ),
        ];
    }

    private function attrEvent(string $field, string $value, int $at): array
    {
        return ['recorded_at' => $at, 'source' => 'A', 'op' => 'set', 'kind' => 'attribute', 'field' => $field, 'value' => $value];
    }

    /** @return list<string> the attribute fields present in SK_1's stored snapshot */
    private function snapshotFields(InMemoryClaimStore $store): array
    {
        $fields = [];
        foreach ($store->loadKeys(['SK_1'])['SK_1']['claims'] as $c) {
            if (($c['kind'] ?? null) === 'attribute') {
                $fields[] = $c['data']['field'];
            }
        }
        sort($fields);

        return array_values(array_unique($fields));
    }

    public function test_the_backfill_fingerprint_is_pre_alias_so_a_replay_stays_a_noop(): void
    {
        $store = new InMemoryClaimStore();
        $env = $this->rawMap([$this->attrEvent('name', 'Old', 10)]);

        ClaimIngest::backfill($store, [$env]);
        $replay = ClaimIngest::backfill($store, [$env], null, self::ALIASES);

        self::assertSame(0, $replay['accepted']);
        self::assertSame(1, $replay['skipped']);
        self::assertSame(0, $replay['appended']);
    }

    public function test_live_resubmission_of_an_old_name_claim_is_a_noop_under_the_alias(): void
    {
        $store = new InMemoryClaimStore();
        $env = $this->rawMap([$this->attrEvent('name', 'X', 10)]);

        ClaimIngest::live($store, [$env]);
        $second = ClaimIngest::live($store, [$env], null, self::ALIASES);

        self::assertSame(0, $second['appended'], 'stored and incoming claims must compare post-alias');
    }

    public function test_a_rename_folds_as_one_dimension_and_the_snapshot_self_heals(): void
    {
        $store = new InMemoryClaimStore();

        // Yesterday's world: backfilled before the rename, the snapshot speaks the old name.
        ClaimIngest::backfill($store, [$this->rawMap([$this->attrEvent('name', 'Old', 10)])]);
        self::assertSame(['name'], $this->snapshotFields($store));

        // The rename ships: live ingest under the new name, alias map injected.
        ClaimIngest::live($store, [$this->rawMap([$this->attrEvent('title', 'New', 20)])], null, self::ALIASES);

        // The rewritten snapshot converged to the terminal name — no split dimension left behind.
        self::assertSame(['title'], $this->snapshotFields($store));

        $record = StoreProjection::record($store, 'SK_1', null, self::ALIASES);
        self::assertCount(1, $record['attributes']);
        [$field, $decision] = $record['attributes'][0];
        self::assertSame('title', $field);
        self::assertSame('New', $decision->value);
    }

    public function test_store_projection_aliases_an_unhealed_snapshot_at_read_time(): void
    {
        $store = new InMemoryClaimStore();

        // Both spellings land pre-rename (no aliases at write time): the snapshot holds the split.
        ClaimIngest::backfill($store, [$this->rawMap([
            $this->attrEvent('name', 'Old', 10),
            $this->attrEvent('title', 'New', 20),
        ])]);
        self::assertSame(['name', 'title'], $this->snapshotFields($store));

        $split = StoreProjection::record($store, 'SK_1');
        self::assertCount(2, $split['attributes']);

        $healed = StoreProjection::record($store, 'SK_1', null, self::ALIASES);
        self::assertCount(1, $healed['attributes']);
        [$field, $decision] = $healed['attributes'][0];
        self::assertSame('title', $field);
        self::assertSame('New', $decision->value);
    }
}
