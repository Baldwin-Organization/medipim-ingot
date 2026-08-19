<?php

declare(strict_types=1);

namespace Ingot\Storage;

/**
 * The reference {@see ClaimStore} — an in-memory adapter used by the package's tests and as the
 * executable spec a DBAL adapter must match. No locking is needed (single process, single thread):
 * {@see transactionally} just runs the closure.
 */
final class InMemoryClaimStore implements ClaimStore
{
    /** @var list<array<string,mixed>> */
    private array $events = [];

    /** @var array<string, array{lane: string, codes: array<string, array{0:string,1:string}>, claims: list<array<string,mixed>>, last_seq: int}> */
    private array $snapshots = [];

    /** @var array<string, array{key: string, lane: string}> code => placement */
    private array $members = [];

    /** @var array<string, array<string, true>> reverse index: key => its member code keys */
    private array $keyCodes = [];

    private int $maxSeq = 0;

    /** @var array<string, array{new_key: string, at: mixed}> */
    private array $redirects = [];

    /** @var array<string, int> */
    private array $laneSeq = [];

    /** @var array<string, true> */
    private array $backfillSeen = [];

    /** @var array<string, array{0:string,1:string}> */
    private array $shared = [];

    /** @var array<string, array{surrogate_key: string, placement: string}> keyed "sourceSystem\x1flegacyEntity" */
    private array $legacyXref = [];

    public function transactionally(callable $fn): mixed
    {
        return $fn();
    }

    public function maxSeq(): int
    {
        return $this->maxSeq;
    }

    public function appendEvents(array $events): void
    {
        foreach ($events as $e) {
            $this->events[] = $e;
            $this->maxSeq = max($this->maxSeq, (int) $e['order']);
        }
    }

    public function log(): array
    {
        $log = $this->events;
        usort($log, static fn (array $a, array $b): int => $a['order'] <=> $b['order']);

        return $log;
    }

    public function resolveKeys(array $codeKeys): array
    {
        $out = [];
        foreach ($codeKeys as $ck) {
            if (isset($this->members[$ck])) {
                $out[$ck] = $this->members[$ck]['key'];
            }
        }

        return $out;
    }

    public function resolveKey(string $codeKey): ?string
    {
        $key = $this->members[$codeKey]['key'] ?? null;
        if ($key === null) {
            return null;
        }

        // Follow redirects to the live key.
        while (isset($this->redirects[$key])) {
            $key = $this->redirects[$key]['new_key'];
        }

        return $key;
    }

    public function loadKeys(array $surrogateKeys): array
    {
        $out = [];
        foreach ($surrogateKeys as $k) {
            if (isset($this->snapshots[$k])) {
                $out[$k] = $this->snapshots[$k];
            }
        }

        return $out;
    }

    public function saveKey(string $surrogateKey, string $lane, array $codes, array $claims, int $lastSeq): void
    {
        $this->snapshots[$surrogateKey] = [
            'lane' => $lane,
            'codes' => $codes,
            'claims' => array_values($claims),
            'last_seq' => $lastSeq,
        ];

        // Rewrite this key's `members` rows to exactly its current code-set (via the reverse
        // index — a full members scan per write is quadratic across a multi-batch backfill).
        // A row another key claimed since stays that key's: only rows still pointing here go.
        foreach ($this->keyCodes[$surrogateKey] ?? [] as $code => $_) {
            if (($this->members[$code]['key'] ?? null) === $surrogateKey) {
                unset($this->members[$code]);
            }
        }
        $this->keyCodes[$surrogateKey] = [];
        foreach ($codes as $codeKey => $_pair) {
            $this->members[$codeKey] = ['key' => $surrogateKey, 'lane' => $lane];
            $this->keyCodes[$surrogateKey][$codeKey] = true;
        }
    }

    public function removeKey(string $surrogateKey): void
    {
        unset($this->snapshots[$surrogateKey]);
        foreach ($this->keyCodes[$surrogateKey] ?? [] as $code => $_) {
            if (($this->members[$code]['key'] ?? null) === $surrogateKey) {
                unset($this->members[$code]);
            }
        }
        unset($this->keyCodes[$surrogateKey]);
    }

    public function addRedirect(string $oldKey, string $newKey, mixed $at): void
    {
        $this->redirects[$oldKey] = ['new_key' => $newKey, 'at' => $at];

        foreach ($this->legacyXref as $lookupKey => $row) {
            if ($row['surrogate_key'] === $oldKey) {
                $this->legacyXref[$lookupKey] = ['surrogate_key' => $newKey, 'placement' => 'merged'];
            }
        }
    }

    public function laneNext(string $lane): int
    {
        return $this->laneSeq[$lane] ?? 1;
    }

    public function setLaneNext(string $lane, int $next): void
    {
        $this->laneSeq[$lane] = $next;
    }

    public function backfillSeen(string $legacyEntity, string $fingerprint): bool
    {
        return isset($this->backfillSeen[$legacyEntity."\x1f".$fingerprint]);
    }

    public function markBackfillSeen(string $legacyEntity, string $fingerprint): void
    {
        $this->backfillSeen[$legacyEntity."\x1f".$fingerprint] = true;
    }

    public function addShared(array $codes): void
    {
        $this->shared += $codes;
    }

    public function allShared(): array
    {
        return $this->shared;
    }

    public function saveLegacyXref(string $sourceSystem, string $legacyEntity, string $surrogateKey, string $placement = 'stable'): void
    {
        $this->legacyXref[$sourceSystem."\x1f".$legacyEntity] = ['surrogate_key' => $surrogateKey, 'placement' => $placement];
    }

    public function resolveLegacy(string $sourceSystem, string $legacyEntity): ?string
    {
        $key = $this->legacyXref[$sourceSystem."\x1f".$legacyEntity]['surrogate_key'] ?? null;
        if ($key === null) {
            return null;
        }

        while (isset($this->redirects[$key])) {
            $key = $this->redirects[$key]['new_key'];
        }

        return $key;
    }

    public function resolveSurrogate(string $surrogateKey): string
    {
        while (isset($this->redirects[$surrogateKey])) {
            $surrogateKey = $this->redirects[$surrogateKey]['new_key'];
        }

        return $surrogateKey;
    }

    public function resolveLegacies(array $pairs): array
    {
        $out = [];
        foreach ($pairs as [$sourceSystem, $legacyEntity]) {
            $key = $this->resolveLegacy($sourceSystem, $legacyEntity);
            if ($key !== null) {
                $out[$sourceSystem."\x1f".$legacyEntity] = $key;
            }
        }

        return $out;
    }
}
