<?php

declare(strict_types=1);

namespace Ingot\Storage;

use Ingot\Claim;
use Ingot\ClaimMapping;
use Ingot\Codes;
use Ingot\ConflictFlagged;
use Ingot\DomainEvent;
use Ingot\Envelope;
use Ingot\EnvelopeLoader;
use Ingot\Events;
use Ingot\IdentitiesMerged;
use Ingot\IdentityRetracted;
use Ingot\Lanes;
use Ingot\LedgerState;
use Ingot\Substrate;

/**
 * The persistent writer — the PHP counterpart of the Elixir `Api.Writes` + `Api.Store`, over a
 * {@see ClaimStore} port. Two paths share ONE reconcile pipeline:
 *
 *   - {@see backfill} — contract-C envelopes (full delta history), idempotent per envelope via a
 *     content fingerprint in `backfill_seen`. ClaimMapping folds each envelope to its CURRENT
 *     code-set, so a backfilled entity is correct on its own.
 *   - {@see live} — current-truth envelopes (from the snapshot translator), idempotent per slot:
 *     a claim whose slot already holds identical content is skipped, so an unchanged write is a
 *     no-op.
 *
 * Per write it loads ONLY the keys whose codes the batch touches (not a global snapshot), reconciles
 * the batch against that subgraph (mint / extend / split / GATED merge proposal — established keys
 * are never auto-merged), appends claims + identity events, and re-projects the touched keys'
 * per-key snapshots. Each key's code-set is derived from its CURRENT identity claims, so a retracted
 * code is dropped from the read truth.
 */
final class ClaimIngest
{
    /**
     * Backfill full-history envelopes (idempotent per envelope).
     *
     * @param list<array<string,mixed>> $envelopeMaps decoded envelope maps (see {@see \Ingot\EnvelopeDecoder})
     * @return array<string,mixed> a summary, or ['errors' => ...] on invalid input
     */
    public static function backfill(ClaimStore $store, array $envelopeMaps, mixed $at = null): array
    {
        [$ok, $envelopes, $errors] = self::decodeEnvelopes($envelopeMaps);
        if (!$ok) {
            return ['errors' => $errors];
        }

        return $store->transactionally(static function () use ($store, $envelopes, $at): array {
            $fresh = [];
            foreach ($envelopes as $env) {
                $fp = self::fingerprint($env);
                $entity = (string) ($env->legacyEntity ?? '');
                if ($store->backfillSeen($entity, $fp)) {
                    continue;
                }
                $fresh[] = [$env, $fp, $entity];
            }

            if ($fresh === []) {
                return self::summary(0, count($envelopes), 0, []);
            }

            $built = ClaimMapping::build(array_map(static fn (array $f): Envelope => $f[0], $fresh));
            $result = self::pipeline($store, $built['claims'], $built['shared'], $at, false);

            foreach ($fresh as [$_env, $fp, $entity]) {
                $store->markBackfillSeen($entity, $fp);
            }

            return self::summary(count($fresh), count($envelopes) - count($fresh), $result['appended'], $result['identity']);
        });
    }

    /**
     * Ingest current-truth envelopes (idempotent per slot) — the live path.
     *
     * @param list<array<string,mixed>> $envelopeMaps
     * @return array<string,mixed>
     */
    public static function live(ClaimStore $store, array $envelopeMaps, mixed $at = null): array
    {
        [$ok, $envelopes, $errors] = self::decodeEnvelopes($envelopeMaps);
        if (!$ok) {
            return ['errors' => $errors];
        }

        return $store->transactionally(static function () use ($store, $envelopes, $at): array {
            $built = ClaimMapping::build($envelopes);
            // The live batch is the source's CURRENT truth, not a replay of its history: keep only
            // the last claim per slot (the cutover's `compact`), so re-running converges. The
            // UNCOMPACTED claims still anchor the subgraph load (gr-iy5): a fully delisted listing
            // compacts to an identity claim with NO codes, and only its earlier periods can name
            // the key that must be loaded — and retracted. (Elixir folds full state instead.)
            $compacted = self::onLiveCodes(Substrate::current($built['claims']));
            $result = self::pipeline($store, $compacted, $built['shared'], $at, true, $built['claims']);

            return self::summary($result['appended'] > 0 ? 1 : 0, 0, $result['appended'], $result['identity']);
        });
    }

    // ── the shared reconcile pipeline ───────────────────────────────────────────

    /**
     * Drop claims addressed to a code no identity in this batch still asserts.
     *
     * Since claims carry intervals (gr-blb), compaction can keep the last claim for a slot whose
     * code has since LEFT every listing — a barcode that moved to another pack. Such a claim is
     * already unreachable: Survivorship::fieldDecisions only keeps attributes whose code is in an
     * identity's member set, and a code-based read joins through code ownership, which no longer
     * has a row. It cannot be projected by anything.
     *
     * Keeping it is not merely useless, it breaks convergence: winnow decides what is already
     * stored by resolving a claim's code to a surrogate key, a departed code resolves to none, so
     * the claim is invisible to that check and gets re-appended on every run (gr-xfw).
     *
     * Live only. The backfill path deliberately keeps the whole history, intervals and all.
     *
     * @param list<Claim> $claims
     * @return list<Claim>
     */
    private static function onLiveCodes(array $claims): array
    {
        $live = [];
        foreach ($claims as $c) {
            if ($c->kind === 'identity') {
                foreach ($c->data['codes'] as $code) {
                    $live[Codes::key($code)] = true;
                }
            }
        }

        $kept = [];
        foreach ($claims as $c) {
            if ($c->kind === 'identity') {
                $kept[] = $c;
                continue;
            }
            foreach (self::loadAnchors($c) as $code) {
                if (!isset($live[Codes::key($code)])) {
                    continue 2;
                }
            }
            $kept[] = $c;
        }

        return $kept;
    }

    /**
     * @param list<Claim> $claims canonical engine claims (from ClaimMapping)
     * @param array<string, array{0:string,1:string}> $shared
     * @param list<Claim>|null $anchorClaims wider anchor set for the subgraph load (live path:
     *        the uncompacted claims, whose earlier periods still carry a delisted listing's codes)
     * @return array{appended: int, identity: list<DomainEvent>}
     */
    private static function pipeline(ClaimStore $store, array $claims, array $shared, mixed $at, bool $winnow, ?array $anchorClaims = null): array
    {
        if ($winnow) {
            $claims = self::winnow($store, $claims);
        }
        if ($claims === []) {
            return ['appended' => 0, 'identity' => []];
        }

        $base = $store->maxSeq();
        $prestamped = self::stampFrom($claims, $base + 1);

        // Load the affected subgraph: every key any batch claim anchors on.
        $loaded = $store->loadKeys(self::affectedKeys($store, $anchorClaims ?? $prestamped));

        // The current view of the affected subgraph + the new batch (last-wins per slot reflects
        // retractions), and the shared codes among all of it. The store speaks arrays; revive.
        $combined = $prestamped;
        foreach ($loaded as $info) {
            foreach ($info['claims'] as $c) {
                $combined[] = Events::fromArray($c);
            }
        }
        $live = Substrate::current($combined);
        $sharedAll = self::sharedOf($live, $shared);

        $ledgers = self::buildLedgers($store, $loaded);
        $atResolved = self::reconcileAt($prestamped) ?? $at ?? time();
        [$identityEvents, $ledgers2] = Lanes::reconcile($live, $sharedAll, $ledgers, $atResolved);

        $identityStamped = self::stampFrom($identityEvents, $base + 1 + count($prestamped));
        $store->appendEvents(Events::toArrays(array_merge($prestamped, $identityStamped)));
        $seq = $base + count($prestamped) + count($identityStamped);

        self::persistLedger($store, $ledgers2);
        self::reproject($store, $ledgers2, $live, $identityStamped, $seq);

        return ['appended' => count($prestamped), 'identity' => $identityStamped];
    }

    /**
     * Drop claims whose slot already holds identical content (in-store OR earlier in the batch) —
     * the live path's per-slot idempotency, mirroring Elixir's `winnow`.
     *
     * @param list<Claim> $claims
     * @return list<Claim>
     */
    private static function winnow(ClaimStore $store, array $claims): array
    {
        $loaded = $store->loadKeys(self::affectedKeys($store, $claims));

        $view = [];
        foreach ($loaded as $info) {
            foreach ($info['claims'] as $c) {
                $stored = Events::fromArray($c);
                $view[self::slotKey($stored)] = self::claimIdentity($stored);
            }
        }

        $kept = [];
        foreach ($claims as $c) {
            $sk = self::slotKey($c);
            $id = self::claimIdentity($c);
            if (($view[$sk] ?? null) === $id) {
                continue;
            }
            $view[$sk] = $id;
            $kept[] = $c;
        }

        return $kept;
    }

    /**
     * Every existing surrogate key any batch claim anchors on (identity codes + grouping/attribute
     * codes + edge endpoints) — the keys we must load to reconcile and re-project correctly.
     *
     * @param list<Claim> $claims
     * @return list<string>
     */
    private static function affectedKeys(ClaimStore $store, array $claims): array
    {
        $codeKeys = [];
        foreach ($claims as $c) {
            foreach (self::loadAnchors($c) as $code) {
                $codeKeys[Codes::key($code)] = true;
            }
        }

        $resolved = $store->resolveKeys(array_keys($codeKeys));

        $keys = [];
        foreach ($resolved as $key) {
            $keys[$key] = true;
        }

        return array_keys($keys);
    }

    /**
     * @param array<string, array{lane: string, codes: array<string, array{0:string,1:string}>, claims: list<array<string,mixed>>, last_seq: int}> $loaded
     * @return array<string, LedgerState>
     */
    private static function buildLedgers(ClaimStore $store, array $loaded): array
    {
        $byLane = array_fill_keys(Lanes::lanes(), []);
        foreach ($loaded as $key => $info) {
            $byLane[$info['lane']][$key] = $info['codes'];
        }

        $ledgers = [];
        foreach (Lanes::lanes() as $lane) {
            $ledgers[$lane] = new LedgerState($byLane[$lane], $store->laneNext($lane), Lanes::prefix($lane));
        }

        return $ledgers;
    }

    /** @param array<string, LedgerState> $ledgers */
    private static function persistLedger(ClaimStore $store, array $ledgers): void
    {
        foreach ($ledgers as $lane => $ledger) {
            $store->setLaneNext($lane, $ledger->next);
        }
    }

    /**
     * Re-home claims to their post-reconcile key and rewrite each touched key's per-key snapshot.
     * A key's code-set is derived from its CURRENT identity claims, so retractions shrink it.
     *
     * @param array<string, LedgerState> $ledgers2
     * @param list<Claim> $live the current view of the affected subgraph + new batch
     * @param list<DomainEvent> $identityEvents
     */
    private static function reproject(ClaimStore $store, array $ledgers2, array $live, array $identityEvents, int $seq): void
    {
        $flat = self::flatMembers($ledgers2);

        $byKey = [];
        foreach ($live as $c) {
            $key = self::claimKey($c, $flat);
            if ($key !== null) {
                $byKey[$key][] = $c;
            }
        }

        // Merges (defensive — reconcile gates merges, so this is rare): redirect + drop absorbed keys.
        foreach ($identityEvents as $e) {
            if ($e instanceof IdentitiesMerged) {
                foreach ($e->from as $from) {
                    if ($from !== $e->into) {
                        $store->addRedirect($from, $e->into, $e->recordedAt);
                        $store->removeKey($from);
                        unset($byKey[$from]);
                    }
                }
            }
            // A retracted key has no live claims left to flow through $byKey — drop its rows
            // here or the store answers with the retired key forever (gr-iy5).
            if ($e instanceof IdentityRetracted) {
                $store->removeKey($e->key);
                unset($byKey[$e->key]);
            }
        }

        foreach ($byKey as $key => $claims) {
            $lane = Lanes::laneOfKey($key);
            $codes = self::codesFromClaims($claims);
            if ($codes === []) {
                $store->removeKey($key);

                continue;
            }
            $store->saveKey($key, $lane, $codes, Events::toArrays(Substrate::current($claims)), $seq);
        }
    }

    // ── anchors / keys ──────────────────────────────────────────────────────────

    /**
     * Codes to LOAD a claim's keys by: identity codes, grouping/attribute code, BOTH edge endpoints.
     *
     * @return list<array{0:string,1:string}>
     */
    private static function loadAnchors(Claim $c): array
    {
        return match ($c->kind) {
            'identity' => array_values($c->data['codes']),
            'grouping', 'attribute' => [$c->data['code']],
            'edge' => array_values(array_filter(
                [$c->data['from'] ?? null, $c->data['to'] ?? null],
                static fn (mixed $x): bool => is_array($x),
            )),
            default => [],
        };
    }

    /**
     * The code a claim HOMES on (which key it belongs to): an edge homes on its `from` endpoint.
     *
     * @return list<array{0:string,1:string}>
     */
    private static function homeAnchors(Claim $c): array
    {
        return match ($c->kind) {
            'identity' => array_values($c->data['codes']),
            'grouping', 'attribute' => [$c->data['code']],
            'edge' => isset($c->data['from']) && is_array($c->data['from']) ? [$c->data['from']] : [],
            default => [],
        };
    }

    /**
     * @param array<string,string> $flat code key => surrogate key
     */
    private static function claimKey(Claim $c, array $flat): ?string
    {
        foreach (self::homeAnchors($c) as $code) {
            $key = $flat[Codes::key($code)] ?? null;
            if ($key !== null) {
                return $key;
            }
        }

        return null;
    }

    /**
     * @param array<string, LedgerState> $ledgers
     * @return array<string,string> code key => surrogate key
     */
    private static function flatMembers(array $ledgers): array
    {
        $flat = [];
        foreach ($ledgers as $ledger) {
            foreach ($ledger->members as $key => $codes) {
                foreach ($codes as $codeKey => $_code) {
                    $flat[$codeKey] = $key;
                }
            }
        }

        return $flat;
    }

    /**
     * A key's code-set from its current identity claims (the read truth — retractions applied).
     *
     * @param list<Claim> $claims
     * @return array<string, array{0:string,1:string}>
     */
    private static function codesFromClaims(array $claims): array
    {
        $codes = [];
        foreach ($claims as $c) {
            if ($c->kind === 'identity') {
                foreach ($c->data['codes'] as $code) {
                    $codes[Codes::key($code)] = $code;
                }
            }
        }

        return $codes;
    }

    // ── helpers ──────────────────────────────────────────────────────────────────

    /**
     * @param list<Claim> $claims
     * @param array<string, array{0:string,1:string}> $extra
     * @return array<string, array{0:string,1:string}>
     */
    private static function sharedOf(array $claims, array $extra): array
    {
        $out = $extra;
        foreach ($claims as $c) {
            if ($c->kind !== 'identity') {
                continue;
            }
            foreach ($c->data['codes'] as $code) {
                if (ClaimMapping::isShared($code)) {
                    $out[Codes::key($code)] = $code;
                }
            }
        }

        return $out;
    }

    /**
     * @param list<DomainEvent> $events
     * @return list<DomainEvent>
     */
    private static function stampFrom(array $events, int $start): array
    {
        $out = [];
        $i = $start;
        foreach ($events as $e) {
            $out[] = $e->withOrder($i);
            ++$i;
        }

        return $out;
    }

    /** @param list<Claim> $claims */
    private static function reconcileAt(array $claims): mixed
    {
        $at = null;
        foreach ($claims as $c) {
            if ($c->kind === 'identity') {
                $at = $at === null ? $c->recordedAt : max($at, $c->recordedAt);
            }
        }

        return $at;
    }

    private static function slotKey(Claim $claim): string
    {
        return Substrate::slotKey(Substrate::slot($claim));
    }

    /** The deterministic claim identity (idempotent resubmission): {source, kind, data, valid_from}. */
    private static function claimIdentity(Claim $claim): string
    {
        return json_encode([$claim->source, $claim->kind, $claim->data, $claim->validFrom], JSON_THROW_ON_ERROR);
    }

    /**
     * @param list<array<string,mixed>> $envelopeMaps
     * @return array{0: bool, 1: list<Envelope>, 2: list<array<string,mixed>>}
     */
    private static function decodeEnvelopes(array $envelopeMaps): array
    {
        $envelopes = [];
        $errors = [];
        foreach ($envelopeMaps as $i => $map) {
            // Raw contract-C maps are validated by the loader into Envelope objects.
            [$ok, $env] = EnvelopeLoader::fromMap($map);
            if ($ok === 'ok') {
                $envelopes[] = $env;
            } else {
                $errors[] = ['index' => $i, 'error' => $env];
            }
        }

        return [$errors === [], $envelopes, $errors];
    }

    /** Content fingerprint for replay-is-a-no-op (stable for identical content). */
    private static function fingerprint(Envelope $env): string
    {
        return hash('sha256', json_encode($env->toArray(), JSON_THROW_ON_ERROR));
    }

    /**
     * @param list<DomainEvent> $identityEvents
     * @return array<string,mixed>
     */
    private static function summary(int $accepted, int $skipped, int $appended, array $identityEvents): array
    {
        $flagged = [];
        foreach ($identityEvents as $e) {
            if ($e instanceof ConflictFlagged && ($e->subject[0] ?? null) === 'merge') {
                $flagged[] = ['type' => 'merge_proposal', 'keys' => $e->subject[1]];
            }
        }

        return [
            'accepted' => $accepted,
            'skipped' => $skipped,
            'appended' => $appended,
            'identity' => array_map(static function (DomainEvent $e): array {
                $tagged = $e->toArray();

                return ['type' => $tagged['type'], 'key' => $tagged['key'] ?? null];
            }, $identityEvents),
            'flagged' => $flagged,
        ];
    }
}
