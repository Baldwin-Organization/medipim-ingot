<?php

declare(strict_types=1);

/**
 * php/bench/fold_bench.php — the PHP side of the cold/warm fold benchmark.
 *
 * Workload = load the 422156 fixture + run the full ingest fold to the final golden record
 * (GoldenRecords::fromEnvelopes). Two modes:
 *
 *   WARM (default):  load the fixture ONCE, then fold N times (default 2000), timing each fold with
 *                    hrtime(true). Reports median + p99 µs/fold and folds/sec as JSON.
 *   COLD (--cold):   one fold, then exit — so a fresh `php -d opcache.enable_cli=1` invocation times
 *                    the whole interpreter+autoload+fold path. run.sh averages ~20 such invocations.
 *
 * Usage:
 *   php -d opcache.enable_cli=1 php/bench/fold_bench.php [--iterations=2000]
 *   php -d opcache.enable_cli=1 php/bench/fold_bench.php --cold
 */

require __DIR__.'/../vendor/autoload.php';

use Ingot\EnvelopeLoader;
use Ingot\GoldenRecords;

$fixture = __DIR__.'/../../test/ingest/fixtures/medipim_be_422156.json';

$argvOpts = getopt('', ['cold', 'iterations::']);
$cold = isset($argvOpts['cold']);
$iterations = isset($argvOpts['iterations']) ? max(1, (int) $argvOpts['iterations']) : 2000;

/** One full fold: parse the already-read envelope + project to the golden record. */
$fold = static function (\Ingot\Envelope $env): array {
    return GoldenRecords::fromEnvelopes([$env], 1);
};

if ($cold) {
    // COLD: the timed unit is this whole process. We still parse + fold once so the work is real;
    // the wall-clock is measured by `time` around the invocation in run.sh.
    $env = EnvelopeLoader::loadBang($fixture);
    $records = $fold($env)['records'];
    // touch the result so nothing is optimized away
    fwrite(STDERR, 'cold fold: '.count($records)." product(s)\n");
    exit(0);
}

// WARM: load the fixture once, then fold N times, timing each.
$env = EnvelopeLoader::loadBang($fixture);

// warm-up (let opcache settle, prime any lazy state)
for ($i = 0; $i < 50; ++$i) {
    $fold($env);
}

$samples = [];
for ($i = 0; $i < $iterations; ++$i) {
    $t0 = hrtime(true);
    $fold($env);
    $samples[] = (hrtime(true) - $t0) / 1000.0; // nanoseconds -> microseconds
}

sort($samples);
$median = $samples[intdiv(count($samples), 2)];
$p99 = $samples[(int) floor(count($samples) * 0.99)];
$mean = array_sum($samples) / count($samples);

echo json_encode([
    'lang' => 'php',
    'mode' => 'warm',
    'php_version' => PHP_VERSION,
    'iterations' => $iterations,
    'median_us' => round($median, 2),
    'p99_us' => round($p99, 2),
    'mean_us' => round($mean, 2),
    'folds_per_sec' => round(1_000_000 / $median, 1),
], JSON_PRETTY_PRINT).PHP_EOL;
