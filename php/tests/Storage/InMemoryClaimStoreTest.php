<?php

declare(strict_types=1);

namespace Ingot\Tests\Storage;

use Ingot\Codes;
use Ingot\Storage\InMemoryClaimStore;
use PHPUnit\Framework\TestCase;

/**
 * The store-level contract for the durable shared-codes map (gh-119) and the legacy cross-reference
 * (gh-120) — exercised directly against the reference in-memory adapter, independent of ClaimIngest.
 */
final class InMemoryClaimStoreTest extends TestCase
{
    // ── shared codes (gh-119) ────────────────────────────────────────────────────

    public function test_shared_starts_empty(): void
    {
        $store = new InMemoryClaimStore();
        self::assertSame([], $store->allShared());
    }

    public function test_added_shared_codes_are_reloadable(): void
    {
        $store = new InMemoryClaimStore();
        $code = ['gtin', '02000000000017'];

        $store->addShared([Codes::key($code) => $code]);

        self::assertSame([Codes::key($code) => $code], $store->allShared());
    }

    public function test_adding_shared_codes_is_add_only_and_unions(): void
    {
        $store = new InMemoryClaimStore();
        $a = ['gtin', '02000000000017'];
        $b = ['artg_id', '207479'];

        $store->addShared([Codes::key($a) => $a]);
        $store->addShared([Codes::key($b) => $b]);

        self::assertSame(
            [Codes::key($a) => $a, Codes::key($b) => $b],
            $store->allShared(),
        );
    }

    // ── legacy xref (gh-120) ─────────────────────────────────────────────────────

    public function test_resolve_legacy_is_null_before_any_xref_is_saved(): void
    {
        $store = new InMemoryClaimStore();
        self::assertNull($store->resolveLegacy('medipim-be', '422156'));
    }

    public function test_saved_legacy_xref_resolves_to_its_surrogate_key(): void
    {
        $store = new InMemoryClaimStore();
        $store->saveLegacyXref('medipim-be', '422156', 'SK_1');

        self::assertSame('SK_1', $store->resolveLegacy('medipim-be', '422156'));
    }

    public function test_resolve_legacies_bulk_resolves_only_hits(): void
    {
        $store = new InMemoryClaimStore();
        $store->saveLegacyXref('medipim-be', '422156', 'SK_1');
        $store->saveLegacyXref('medipim-fr', '347025', 'SK_2');

        $resolved = $store->resolveLegacies([
            ['medipim-be', '422156'],
            ['medipim-fr', '347025'],
            ['medipim-be', '999999'],
        ]);

        self::assertSame([
            "medipim-be\x1f422156" => 'SK_1',
            "medipim-fr\x1f347025" => 'SK_2',
        ], $resolved);
    }

    public function test_resolve_legacy_follows_redirects_to_the_live_key(): void
    {
        $store = new InMemoryClaimStore();
        $store->saveLegacyXref('medipim-be', '422156', 'SK_1');

        $store->addRedirect('SK_1', 'SK_2', 100);

        self::assertSame('SK_2', $store->resolveLegacy('medipim-be', '422156'));
    }

    public function test_addRedirect_updates_xref_rows_pointing_at_the_old_key(): void
    {
        // Even a store that never re-resolves (a stale read) should see the row itself retagged
        // merged and repointed — resolveLegacy following redirects is a defensive backstop, not a
        // substitute for keeping the row live.
        $store = new InMemoryClaimStore();
        $store->saveLegacyXref('medipim-be', '422156', 'SK_1', 'stable');
        $store->saveLegacyXref('medipim-be', '999999', 'SK_9', 'stable');

        $store->addRedirect('SK_1', 'SK_2', 100);

        self::assertSame('SK_2', $store->resolveLegacy('medipim-be', '422156'));
        // An unrelated row stays untouched.
        self::assertSame('SK_9', $store->resolveLegacy('medipim-be', '999999'));
    }
}
