<?php

declare(strict_types=1);

namespace Ingot\Tests;

use PHPUnit\Framework\TestCase;

/**
 * Keeps the committed API parity fixture reproducible from the independent PHP engine and the real
 * medipim envelopes. The subprocess matters: it proves the oracle remains directly executable,
 * rather than only testing helpers loaded into PHPUnit.
 */
final class ShadowWindowOracleTest extends TestCase
{
    private const ORACLE = __DIR__.'/../bench/dump_medipim_shadow_window.php';
    private const EXPECTED = __DIR__.'/../../api/test/fixtures/medipim_shadow_window.expected.json';

    public function test_committed_shadow_window_is_reproducible(): void
    {
        $command = escapeshellarg(PHP_BINARY).' '.escapeshellarg(self::ORACLE);
        $lines = [];
        $status = null;
        exec($command, $lines, $status);

        self::assertSame(0, $status, 'the executable PHP shadow-window oracle failed');
        self::assertFileExists(self::EXPECTED);
        self::assertSame(
            file_get_contents(self::EXPECTED),
            implode(PHP_EOL, $lines).PHP_EOL,
            'run `php php/bench/dump_medipim_shadow_window.php > api/test/fixtures/medipim_shadow_window.expected.json`',
        );
    }
}
