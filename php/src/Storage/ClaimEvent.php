<?php

declare(strict_types=1);

namespace Ingot\Storage;

use Ingot\Events;
use Ingot\Lanes;

/**
 * Maps an engine event (a tagged assoc array — see {@see Events}) to the scalar columns of the
 * `events` table, so the DBAL adapter (and the in-memory store) derive `type`/`kind`/`lane`/
 * `source`/`recorded_at`/`valid_from` ONE way. The full event is always also stored as `payload`.
 */
final class ClaimEvent
{
    /**
     * @param array<string,mixed> $event
     * @return array{seq: int, type: string, kind: ?string, lane: ?string, source: ?string, recorded_at: mixed, valid_from: mixed}
     */
    public static function columns(array $event): array
    {
        return [
            'seq' => $event['order'],
            'type' => $event['type'],
            'kind' => $event['kind'] ?? null,
            'lane' => self::lane($event),
            'source' => $event['source'] ?? null,
            'recorded_at' => $event['recorded_at'] ?? null,
            'valid_from' => $event['valid_from'] ?? null,
        ];
    }

    /** The lane an event routes to: a claim's via its codes; an identity event's via its key prefix. */
    public static function lane(array $event): ?string
    {
        if (($event['type'] ?? null) === Events::TYPE_CLAIM_ASSERTED) {
            if (($event['kind'] ?? null) === 'identity') {
                $claim = Events::fromArray($event);
                \assert($claim instanceof \Ingot\Claim);
                $r = Lanes::ofClaim($claim);

                return $r[0] === 'ok' ? $r[1] : null;
            }

            return null;
        }

        if (isset($event['key'])) {
            return Lanes::laneOfKey($event['key']);
        }
        if (isset($event['into']) && \is_string($event['into'])) {
            return Lanes::laneOfKey($event['into']);
        }

        return null;
    }
}
