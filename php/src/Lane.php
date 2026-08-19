<?php

declare(strict_types=1);

namespace Ingot;

/**
 * Typed entity lane — the closed set {@see Lanes} routes identity claims into.
 *
 * Every code scheme belongs to exactly one lane; each lane folds under its own surrogate-key
 * prefix ({@see prefix()}).
 */
enum Lane: string
{
    case Product = 'product';
    case Substance = 'substance';
    case Description = 'description';
    case Media = 'media';

    /** Lane-qualified surrogate-key prefix ('product' keeps the legacy "SK"). */
    public function prefix(): string
    {
        return match ($this) {
            self::Product => 'SK',
            self::Substance => 'SUB',
            self::Description => 'DSC',
            self::Media => 'MED',
        };
    }

    /**
     * Primary synthetic identity scheme that mints a lane record for this lane's aggregate id
     * (descriptions → text_id, media → asset_id, products → product_id). Substance has none.
     */
    public function identityScheme(): ?IdentityScheme
    {
        return IdentityScheme::forLane($this);
    }
}
