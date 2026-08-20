<?php

declare(strict_types=1);

namespace Ingot;

/**
 * The single entry point the consuming application (medipim) calls. Collapses the five-module fold
 * the engine otherwise requires — {@see EnvelopeLoader} → {@see GoldenRecords}/{@see LegacyXref}/
 * {@see MigrationDiff} → {@see Canonical422156} — into one call returning a {@see GoldenRecordResult}.
 *
 * Concrete on purpose: there is one implementation, so there is no interface to mock. A medipim-side
 * adapter that needs to satisfy `ProductCodeLookupRepositoryInterface` wraps this class and maps the
 * engine's surrogate keys to `ProductId`s; it does not subclass it.
 *
 * `$at` is the temporal cut-off the log is re-derived against and is REQUIRED — there is no safe
 * default for "as of when", and a wrong default would silently change which claims win survivorship.
 */
final class GoldenRecordEngine
{
    /**
     * Fold already-validated envelopes into a golden record at time `$at`. `$aliases` is the
     * dimension-alias seam ({@see DimensionAliases}): the old→new field-name map medipim derives
     * from its `#[RenamedFrom]` attributes, applied at fold time so renamed fields resolve as one
     * dimension.
     *
     * @param list<Envelope> $envelopes
     * @param array<string,string> $aliases
     */
    public function ingest(array $envelopes, mixed $at, ?Priority $priority = null, array $aliases = []): GoldenRecordResult
    {
        return new GoldenRecordResult(
            GoldenRecords::fromEnvelopes($envelopes, $at, $priority, $aliases),
            LegacyXref::fromEnvelopes($envelopes, $at),
            MigrationDiff::fromEnvelopes($envelopes, $at),
        );
    }

    /** Convenience: load one envelope file (validating it), then {@see ingest}. */
    public function ingestFile(string $path, mixed $at, ?Priority $priority = null, array $aliases = []): GoldenRecordResult
    {
        return $this->ingest([EnvelopeLoader::loadBang($path)], $at, $priority, $aliases);
    }

    /** Convenience: decode one envelope from a JSON string (throwing on error), then {@see ingest}. */
    public function ingestJson(string $json, mixed $at, ?Priority $priority = null, array $aliases = []): GoldenRecordResult
    {
        [$ok, $env] = EnvelopeLoader::fromJson($json);
        if ($ok !== 'ok') {
            throw new \RuntimeException('invalid envelope JSON: '.json_encode($env));
        }

        return $this->ingest([$env], $at, $priority, $aliases);
    }
}
