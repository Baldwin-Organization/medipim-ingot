<?php

declare(strict_types=1);

namespace Ingot;

/**
 * An immutable set of `Code`s — the value-object face of a `Sets` code-set, so folds read as
 * language: `$held->isEmpty()`, `$mine->union($theirs)`, `$codes->sorted()`.
 *
 * Internally this is exactly the `Sets` representation (assoc array keyed by `Codes::key`), and
 * `fromSets()` / `toSets()` bridge to the engine layers that still speak it. Every operation
 * returns a new set; nothing mutates.
 *
 * @implements \IteratorAggregate<int, Code>
 */
final class CodeSet implements \IteratorAggregate, \Countable
{
    /** @param array<string, array{0: string, 1: string}> $set */
    private function __construct(
        private readonly array $set,
    ) {
    }

    public static function none(): self
    {
        return new self([]);
    }

    public static function of(Code ...$codes): self
    {
        $set = [];
        foreach ($codes as $code) {
            $set[$code->key()] = $code->pair();
        }

        return new self($set);
    }

    /** Boundary in: adopt a `Sets`-shaped code-set. @param array<string, array{0: string, 1: string}> $set */
    public static function fromSets(array $set): self
    {
        return new self($set);
    }

    /** Boundary out: the `Sets` representation the engine fold consumes. @return array<string, array{0: string, 1: string}> */
    public function toSets(): array
    {
        return $this->set;
    }

    public function has(Code $code): bool
    {
        return isset($this->set[$code->key()]);
    }

    public function isEmpty(): bool
    {
        return $this->set === [];
    }

    public function with(Code $code): self
    {
        $set = $this->set;
        $set[$code->key()] = $code->pair();

        return new self($set);
    }

    public function union(self $other): self
    {
        return new self(Sets::union($this->set, $other->set));
    }

    public function equals(self $other): bool
    {
        if (count($this->set) !== count($other->set)) {
            return false;
        }
        foreach ($this->set as $key => $_) {
            if (!isset($other->set[$key])) {
                return false;
            }
        }

        return true;
    }

    /** @return list<Code> deterministically ordered by (scheme, value) */
    public function sorted(): array
    {
        return array_map(Code::fromPair(...), Sets::valuesSorted($this->set));
    }

    public function count(): int
    {
        return count($this->set);
    }

    /** @return \Traversable<int, Code> */
    public function getIterator(): \Traversable
    {
        foreach ($this->set as $pair) {
            yield Code::fromPair($pair);
        }
    }
}
