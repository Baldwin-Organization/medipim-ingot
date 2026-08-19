<?php

declare(strict_types=1);

namespace Ingot\Tests\Storage;

use Ingot\Storage\Schema;
use PHPUnit\Framework\TestCase;

final class SchemaTest extends TestCase
{
    public function test_statements_cover_all_tables_with_prefix(): void
    {
        $sql = implode("\n", Schema::statements('x_'));
        foreach (['x_events', 'x_snapshots', 'x_members', 'x_redirects', 'x_lane_seq', 'x_backfill_seen', 'x_shared', 'x_legacy_xref'] as $table) {
            self::assertStringContainsString("`{$table}`", $sql);
        }
    }

    public function test_shared_table_has_code_scheme_value_columns(): void
    {
        $sql = implode("\n", Schema::statements('x_'));

        self::assertMatchesRegularExpression('/CREATE TABLE IF NOT EXISTS `x_shared`/', $sql);
        self::assertMatchesRegularExpression('/`code` VARCHAR\(191\) NOT NULL/', $sql);
        self::assertMatchesRegularExpression('/`scheme` VARCHAR\(32\) NOT NULL/', $sql);
        self::assertMatchesRegularExpression('/`value` VARCHAR\(160\) NOT NULL/', $sql);
        self::assertMatchesRegularExpression('/PRIMARY KEY \(`code`\)/', $sql);
    }

    public function test_legacy_xref_table_has_composite_key_and_surrogate_index(): void
    {
        $sql = implode("\n", Schema::statements('x_'));

        self::assertMatchesRegularExpression('/CREATE TABLE IF NOT EXISTS `x_legacy_xref`/', $sql);
        self::assertMatchesRegularExpression('/`source_system` VARCHAR\(64\) NOT NULL/', $sql);
        self::assertMatchesRegularExpression('/`legacy_entity` VARCHAR\(64\) NOT NULL/', $sql);
        self::assertMatchesRegularExpression('/`surrogate_key` VARCHAR\(64\) NOT NULL/', $sql);
        self::assertMatchesRegularExpression("/`placement` VARCHAR\\(20\\) NOT NULL DEFAULT 'stable'/", $sql);
        self::assertMatchesRegularExpression('/PRIMARY KEY \(`source_system`, `legacy_entity`\)/', $sql);
        self::assertMatchesRegularExpression('/KEY `x_legacy_xref_surrogate_key` \(`surrogate_key`\)/', $sql);
    }

    public function test_prefix_cannot_escape_identifier_quoting(): void
    {
        $this->expectException(\InvalidArgumentException::class);
        Schema::statements('x` (`a` INT); DROP TABLE users; -- ');
    }
}
