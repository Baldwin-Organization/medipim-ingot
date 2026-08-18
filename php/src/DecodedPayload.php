<?php

declare(strict_types=1);

namespace Ingot;

/**
 * The kind-specific payload of one {@see DecodedEvent} — {@see IdentityDelta},
 * {@see AttributeDelta}, {@see EdgeDelta} or {@see MediaDelta}. `toArray` reproduces the exact
 * payload map {@see EnvelopeLoader} always built, so envelope fingerprints stay byte-identical.
 */
interface DecodedPayload
{
    /** @return array<string,mixed> */
    public function toArray(): array;
}
