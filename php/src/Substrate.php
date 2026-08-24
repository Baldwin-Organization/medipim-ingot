<?php

declare(strict_types=1);

namespace Ingot;

/**
 * Claim construction + the current-view fold — ported from `Substrate` in lib/golden_record_core.ex.
 *
 * Every ingested code is canonicalized here so equivalent representations collapse. `member_of` is
 * the legacy spelling of an `edge`: the constructor lowers it, so the log holds the generalized
 * edge. `current/1` keeps only the latest claim per slot (a slot = the dimension a claim addresses).
 */
final class Substrate
{
    /**
     * Build a {@see Claim}. `member_of` data ({member_code, collection}) lowers to an `edge`.
     *
     * @param array<string,mixed> $data
     */
    public static function claim(?string $source, string $kind, array $data, mixed $validFrom, mixed $recordedAt, mixed $validTo = null, mixed $by = null): Claim
    {
        if ($kind === 'member_of' && isset($data['member_code'], $data['collection'])) {
            return self::claim(
                $source,
                'edge',
                ['from' => $data['member_code'], 'relation' => 'member_of', 'to' => $data['collection']],
                $validFrom,
                $recordedAt,
                $validTo,
                $by
            );
        }

        return Events::claimAsserted($source, $kind, self::normalize($kind, $data), $validFrom, $recordedAt, null, $validTo, $by);
    }

    /**
     * @param array<string,mixed> $data
     * @return array<string,mixed>
     */
    private static function normalize(string $kind, array $data): array
    {
        switch ($kind) {
            case 'identity':
                if (isset($data['codes'])) {
                    $data['codes'] = array_map(Codes::canonicalize(...), $data['codes']);
                }

                return $data;
            case 'identity_evidence':
                if (isset($data['left'], $data['right'])) {
                    $data['left'] = Codes::canonicalize($data['left']);
                    $data['right'] = Codes::canonicalize($data['right']);
                }

                return $data;
            case 'grouping':
            case 'attribute':
                if (isset($data['code'])) {
                    $data['code'] = Codes::canonicalize($data['code']);
                }

                return $data;
            case 'media':
                if (isset($data['target'])) {
                    $data['target'] = Codes::canonicalize($data['target']);
                }

                return $data;
            case 'edge':
                if (isset($data['from'], $data['to'])) {
                    // Elixir canonicalizes BOTH endpoints. For a member_of edge the `to` is a
                    // {collection, member} tuple — Codes::canonicalize just trims its value (the
                    // collection scheme is not GTIN/padded), which is exactly what we want: e.g. a
                    // tab-only member trims to "".
                    $data['from'] = Codes::canonicalize($data['from']);
                    $data['to'] = Codes::canonicalize($data['to']);
                }

                return $data;
            case 'member_of':
                if (isset($data['member_code'], $data['collection'])) {
                    $data['member_code'] = Codes::canonicalize($data['member_code']);
                    $data['collection'] = Codes::canonicalize($data['collection']);
                }

                return $data;
            default:
                return $data;
        }
    }

    /**
     * The slot a claim addresses — its dedup key in `current/1`. Returned as a flat list whose
     * first element is the kind tag, mirroring the Elixir tuple shapes.
     *
     * @return list<mixed>
     */
    public static function slot(Claim $claim): array
    {
        $s = $claim->source;
        $d = $claim->data;

        return match ($claim->kind) {
            'identity' => [$s, 'identity', $d['ref']],
            'identity_evidence' => [$s, 'identity_evidence', $d['left'], $d['right']],
            'grouping' => [$s, 'grouping', $d['code']],
            'attribute' => [$s, 'attr', $d['code'], $d['field']],
            'media' => [$s, 'media', $d['asset'], $d['target']],
            'edge' => [$s, 'edge', $d['from'], $d['relation'], $d['to']],
            'member_of' => [$s, 'member_of', $d['member_code'], $d['collection']],
            default => [$s, $claim->kind],
        };
    }

    /**
     * Collapse the claim log to the latest claim per slot (highest `order` wins). A slot whose
     * latest claim is a {@see retracted} marker has no current claim at all and is dropped.
     *
     * @param list<Claim> $claims
     * @return list<Claim>
     */
    public static function current(array $claims): array
    {
        /** @var array<string, Claim> $bySlot */
        $bySlot = [];
        foreach ($claims as $c) {
            $key = self::slotKey(self::slot($c));
            if (!isset($bySlot[$key]) || ($c->order ?? 0) > ($bySlot[$key]->order ?? 0)) {
                $bySlot[$key] = $c;
            }
        }

        return array_values(array_filter($bySlot, static fn (Claim $c): bool => !self::retracted($c)));
    }

    /**
     * An edge retraction marker (gh-131): the live writer appends the omitted edge again with
     * `data.retracted = true`, so the log keeps the audit trail while the current view drops the
     * slot. The marker is an ordinary claim — it wins its slot by `order`, and a later re-assertion
     * of the same edge (without the flag) wins it back. Attributes need no marker: a `null` value
     * is already how a backfilled null-set reads, so live omission retracts them the same way.
     */
    public static function retracted(Claim $c): bool
    {
        return $c->kind === 'edge' && ($c->data['retracted'] ?? false) === true;
    }

    /**
     * A stable string key for a slot list (codes are [scheme,value] pairs, collections likewise).
     *
     * @param list<mixed> $slot
     */
    public static function slotKey(array $slot): string
    {
        return implode("\x1e", array_map(static function (mixed $part): string {
            if (is_array($part)) {
                return implode("\x1f", array_map(static fn ($x): string => (string) $x, $part));
            }

            return is_bool($part) ? ($part ? '1' : '0') : (string) $part;
        }, $slot));
    }
}
