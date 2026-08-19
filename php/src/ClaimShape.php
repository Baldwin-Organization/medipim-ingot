<?php

declare(strict_types=1);

namespace Ingot;

/**
 * The claim-mapping shape's version — mixed into {@see \Ingot\Storage\ClaimIngest}'s backfill
 * fingerprint (medipimv2-sgh.12), so a change to how envelopes fold into claims (a `ClaimMapping`
 * change, a new identity field, a code-normalization tweak, ...) invalidates every previously-seen
 * `backfill_seen` marker instead of silently leaving already-ingested entities un-reconciled under
 * the new shape. Bump this whenever `ClaimMapping::build` (or anything upstream of it that changes
 * the claims a given envelope produces) changes in a way that should force a re-ingest.
 */
final class ClaimShape
{
    public const VERSION = 2;
}
