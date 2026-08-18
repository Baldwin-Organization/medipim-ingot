<?php

declare(strict_types=1);

namespace Ingot\Tests;

use Ingot\EnvelopeLoader;
use Ingot\GoldenRecords;
use Ingot\Priority;
use PHPUnit\Framework\TestCase;

/**
 * PHP-parity mirror of the "survivorship under priority" cases in
 * test/ingest/golden_records_test.exs (gr-6y2): the survivorship policy — a Priority OR an injected
 * `callable(dimension, source)` rank fun — is reachable from the FOLD ENTRY (GoldenRecords), not
 * just Survivorship::decide. The same claims under different injected context yield different
 * winners, which one static Priority cannot express.
 */
final class GoldenRecordsPolicyTest extends TestCase
{
    /** @param list<array<string,mixed>> $events */
    private function envelope(int $entity, array $events): array
    {
        [$ok, $env] = EnvelopeLoader::fromMap(['schema_version' => '1', 'legacy_entity' => $entity, 'events' => $events]);
        self::assertSame('ok', $ok);

        return $env;
    }

    private function id(string $source, string $scheme, string $code, int $at): array
    {
        return ['recorded_at' => $at, 'source' => $source, 'op' => 'set', 'kind' => 'identity', 'scheme' => $scheme, 'code' => $code];
    }

    private function attr(string $source, string $field, mixed $value, int $at): array
    {
        return ['recorded_at' => $at, 'source' => $source, 'op' => 'set', 'kind' => 'attribute', 'field' => $field, 'value' => $value];
    }

    /** @return list<array<string,mixed>> two envelopes for one product (shared CNK), disagreeing on `name`. */
    private function twoSourceConflict(): array
    {
        return [
            $this->envelope(1, [$this->id('A', 'cnk', '555', 10), $this->attr('A', 'name', 'Alpha', 11)]),
            $this->envelope(1, [$this->id('B', 'cnk', '555', 10), $this->attr('B', 'name', 'Beta', 12)]),
        ];
    }

    private function field(\Ingot\Variant $variant, string $name): \Ingot\Decision
    {
        $decision = $variant->attribute($name);
        if ($decision === null) {
            self::fail("field {$name} not found");
        }

        return $decision;
    }

    public function test_permissive_default_surfaces_conflict_as_needs_review(): void
    {
        $gr = GoldenRecords::fromEnvelopes($this->twoSourceConflict(), 1);

        self::assertCount(1, $gr['records']);
        $variant = $gr['records'][0]->variants[0];
        self::assertSame('needs_review', $this->field($variant, 'name')->status);
    }

    public function test_supplied_priority_resolves_to_the_ranked_winner(): void
    {
        $priority = Priority::new([], [['A'], ['B']]);
        $gr = GoldenRecords::fromEnvelopes($this->twoSourceConflict(), 1, $priority);

        $variant = $gr['records'][0]->variants[0];
        $d = $this->field($variant, 'name');
        self::assertSame('Alpha', $d->value);
        self::assertSame('A', $d->winner);
        self::assertSame('resolved', $d->status);
    }

    public function test_injected_policy_fn_reaches_the_fold_entry_and_its_context_picks_the_winner(): void
    {
        $prefer = static fn (string $preferred): callable =>
            static fn (string $dim, ?string $src): int => $src === $preferred ? 0 : 1;

        $grB = GoldenRecords::fromEnvelopes($this->twoSourceConflict(), 1, $prefer('B'));
        $dB = $this->field($grB['records'][0]->variants[0], 'name');
        self::assertSame('Beta', $dB->value);
        self::assertSame('B', $dB->winner);
        self::assertSame('resolved', $dB->status);

        $grA = GoldenRecords::fromEnvelopes($this->twoSourceConflict(), 1, $prefer('A'));
        $dA = $this->field($grA['records'][0]->variants[0], 'name');
        self::assertSame('Alpha', $dA->value);
        self::assertSame('A', $dA->winner);
        self::assertSame('resolved', $dA->status);
    }
}
