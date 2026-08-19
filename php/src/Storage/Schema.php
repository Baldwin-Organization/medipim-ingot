<?php

declare(strict_types=1);

namespace Ingot\Storage;

/**
 * The claim store's schema as data — the dependency-free twin of the Elixir `Api.Store.migrate!`.
 * The consuming app's migration calls {@see statements} and runs each `CREATE TABLE`, so "make the
 * tables" is one line and the package, not the app, owns the shape. Table names take a configurable
 * prefix (default `claim_`) so an app can namespace them.
 *
 * MySQL/InnoDB + `JSON` columns; timestamps are unix-epoch `BIGINT` (the engine's date-free fold
 * path uses integer `recorded_at`), so nothing here assumes a particular date type.
 */
final class Schema
{
    /**
     * The `CREATE TABLE IF NOT EXISTS` statements, in dependency order.
     *
     * @return list<string>
     */
    public static function statements(string $prefix = 'claim_'): array
    {
        // The prefix is interpolated into identifier quoting below — a backtick in it would
        // escape into arbitrary DDL, so only allow word characters.
        if (!preg_match('/^\w*$/', $prefix)) {
            throw new \InvalidArgumentException("table prefix must match [A-Za-z0-9_]*, got: {$prefix}");
        }
        $p = $prefix;

        return [
            // The append-only log — the system of record. `seq` is the engine's offset, assigned
            // under the writer lock (NOT auto-increment, so the payload carries its own offset).
            <<<SQL
            CREATE TABLE IF NOT EXISTS `{$p}events` (
              `seq` BIGINT UNSIGNED NOT NULL,
              `type` VARCHAR(40) NOT NULL,
              `kind` VARCHAR(20) DEFAULT NULL,
              `lane` VARCHAR(20) DEFAULT NULL,
              `source` VARCHAR(128) DEFAULT NULL,
              `recorded_at` BIGINT DEFAULT NULL,
              `valid_from` BIGINT DEFAULT NULL,
              `payload` JSON NOT NULL,
              `inserted_at` TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
              PRIMARY KEY (`seq`),
              KEY `{$p}events_recorded_at` (`recorded_at`),
              KEY `{$p}events_lane` (`lane`)
            ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4
            SQL,
            // Per-key materialized snapshot: each surrogate key's code-set + current claim view.
            // Disposable — rebuildable by folding `events`.
            <<<SQL
            CREATE TABLE IF NOT EXISTS `{$p}snapshots` (
              `surrogate_key` VARCHAR(64) NOT NULL,
              `lane` VARCHAR(20) NOT NULL,
              `codes` JSON NOT NULL,
              `claims` JSON NOT NULL,
              `last_seq` BIGINT UNSIGNED NOT NULL,
              `updated_at` TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
              PRIMARY KEY (`surrogate_key`),
              KEY `{$p}snapshots_lane` (`lane`)
            ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4
            SQL,
            // code -> key resolution index (the ledger, as queryable rows). lane is the key prefix.
            // `code` is Codes::key output: scheme (registry-bounded, ≤22 chars) + "\x1f" + value.
            // VARCHAR(191) as PK is only safe because EnvelopeLoader caps code values at 160 chars —
            // without that, a non-strict MySQL would silently truncate two distinct >191-char codes
            // onto the same primary key, cross-linking unrelated identities.
            <<<SQL
            CREATE TABLE IF NOT EXISTS `{$p}members` (
              `code` VARCHAR(191) NOT NULL,
              `surrogate_key` VARCHAR(64) NOT NULL,
              `lane` VARCHAR(20) NOT NULL,
              PRIMARY KEY (`code`),
              KEY `{$p}members_key` (`surrogate_key`),
              KEY `{$p}members_lane` (`lane`)
            ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4
            SQL,
            // Merge redirects: a client holding `old_key` resolves forward to `new_key`.
            <<<SQL
            CREATE TABLE IF NOT EXISTS `{$p}redirects` (
              `old_key` VARCHAR(64) NOT NULL,
              `new_key` VARCHAR(64) NOT NULL,
              `at` BIGINT DEFAULT NULL,
              PRIMARY KEY (`old_key`)
            ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4
            SQL,
            // Per-lane mint counter, so a freshly minted key is globally unique within its lane.
            <<<SQL
            CREATE TABLE IF NOT EXISTS `{$p}lane_seq` (
              `lane` VARCHAR(20) NOT NULL,
              `next` BIGINT UNSIGNED NOT NULL,
              PRIMARY KEY (`lane`)
            ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4
            SQL,
            // Backfill idempotency: a per-(entity, content fingerprint) marker.
            <<<SQL
            CREATE TABLE IF NOT EXISTS `{$p}backfill_seen` (
              `legacy_entity` VARCHAR(64) NOT NULL,
              `fingerprint` VARCHAR(64) NOT NULL,
              `inserted_at` TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
              PRIMARY KEY (`legacy_entity`, `fingerprint`)
            ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4
            SQL,
            // The shared-codes map (restricted/non-bridging identity codes) as of the last ingest —
            // add-only, so identity reconcile can be re-run from the store without replaying every
            // envelope ({@see \Ingot\Storage\ClaimIngest}, gh-119).
            <<<SQL
            CREATE TABLE IF NOT EXISTS `{$p}shared` (
              `code` VARCHAR(191) NOT NULL,
              `scheme` VARCHAR(32) NOT NULL,
              `value` VARCHAR(160) NOT NULL,
              PRIMARY KEY (`code`)
            ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4
            SQL,
            // Durable legacy -> surrogate-key cross-reference ({@see \Ingot\LegacyXref}, gh-120):
            // where each (source_system, legacy_entity) currently resolves, and how it got there.
            <<<SQL
            CREATE TABLE IF NOT EXISTS `{$p}legacy_xref` (
              `source_system` VARCHAR(64) NOT NULL,
              `legacy_entity` VARCHAR(64) NOT NULL,
              `surrogate_key` VARCHAR(64) NOT NULL,
              `placement` VARCHAR(20) NOT NULL DEFAULT 'stable',
              PRIMARY KEY (`source_system`, `legacy_entity`),
              KEY `{$p}legacy_xref_surrogate_key` (`surrogate_key`)
            ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4
            SQL,
        ];
    }
}
