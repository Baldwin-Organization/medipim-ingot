<?php

declare(strict_types=1);

namespace Ingot;

/** An attribute delta: one field (optionally per locale) stated by a source. */
final readonly class AttributeDelta implements DecodedPayload
{
    public function __construct(
        public mixed $field,
        public mixed $locale,
        public mixed $value,
    ) {
    }

    public function toArray(): array
    {
        return ['field' => $this->field, 'locale' => $this->locale, 'value' => $this->value];
    }
}
