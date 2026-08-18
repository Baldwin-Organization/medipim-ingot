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
        foreach (['x_events', 'x_snapshots', 'x_members', 'x_redirects', 'x_lane_seq', 'x_backfill_seen'] as $table) {
            self::assertStringContainsString("`{$table}`", $sql);
        }
    }

    public function test_prefix_cannot_escape_identifier_quoting(): void
    {
        $this->expectException(\InvalidArgumentException::class);
        Schema::statements('x` (`a` INT); DROP TABLE users; -- ');
    }
}
