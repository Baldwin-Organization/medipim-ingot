<?php

declare(strict_types=1);

namespace Ingot;

/**
 * Synthetic identity schemes used to mint a lane record when an aggregate's deltas carry no
 * natural market identity code — the anchors {@see EnvelopeDecoder} / {@see SnapshotTranslator}
 * inject via `identity_scheme`.
 *
 * Market codes (cnk, gtin, …) stay outside this enum: they are registry-driven identity fields,
 * not lane anchors.
 */
enum IdentityScheme: string
{
    /** Medipim product aggregate id — never bridges via a market code. */
    case ProductId = 'product_id';

    /** Medipim description aggregate id. */
    case TextId = 'text_id';

    /** Medipim media aggregate id. */
    case AssetId = 'asset_id';

    /** Medipim leaflet aggregate id (media lane; distinct id-space from {@see AssetId}). */
    case LeafletId = 'leaflet_id';

    public function lane(): Lane
    {
        return match ($this) {
            self::ProductId => Lane::Product,
            self::TextId => Lane::Description,
            self::AssetId, self::LeafletId => Lane::Media,
        };
    }

    /**
     * Primary synthetic identity scheme for a lane's own aggregate id.
     * Substance has no synthetic lane-anchor scheme.
     */
    public static function forLane(Lane $lane): ?self
    {
        return match ($lane) {
            Lane::Product => self::ProductId,
            Lane::Description => self::TextId,
            Lane::Media => self::AssetId,
            Lane::Substance => null,
        };
    }

    /** Normalize an opts value that may already be this enum or its wire string. */
    public static function coerce(self|string $scheme): self
    {
        return $scheme instanceof self ? $scheme : self::from($scheme);
    }
}
