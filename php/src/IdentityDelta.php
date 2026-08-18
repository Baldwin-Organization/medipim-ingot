<?php

declare(strict_types=1);

namespace Ingot;

/** An identity delta: one code scheme set/added/removed/deleted on a listing. */
final readonly class IdentityDelta implements DecodedPayload
{
    public function __construct(
        public mixed $scheme,
        public mixed $code,
    ) {
    }

    public function toArray(): array
    {
        return ['scheme' => $this->scheme, 'code' => $this->code];
    }
}
