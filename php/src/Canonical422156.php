<?php

declare(strict_types=1);

namespace Ingot;

/**
 * Canonical-document projection for the 422156 parity oracle — the PHP twin of the canonicalizers
 * in php/bench/dump_golden_422156.exs. Turns a golden-record + xref + diff result into the plain
 * nested map/list-of-scalars shape, with recursively sorted keys, so the two engines' output can be
 * compared byte-for-byte. Codes become "scheme:value" strings; atoms become strings; tuples become
 * strings/arrays.
 */
final class Canonical422156
{
    /**
     * @param array{records: list<GoldenRecord>} $gr
     * @param array{legacy_to_key: array<string, Placement>} $xref
     * @param array<string,mixed> $diff
     * @return array<string,mixed>
     */
    public static function document(array $gr, array $xref, array $diff): array
    {
        $products = [];
        foreach ($gr['records'] as $record) {
            $variants = [];
            foreach ($record->variants as $v) {
                $variants[] = self::variant($v);
            }
            $products[] = ['product' => $record->product, 'variants' => $variants];
        }

        return [
            'products' => $products,
            'xref' => self::xref($xref['legacy_to_key']),
            'diff' => $diff,
        ];
    }

    /** Recursively sort assoc-array keys, then JSON-encode like Elixir's JSON.encode! (no escapes). */
    public static function encode(mixed $document): string
    {
        return json_encode(self::sort($document), JSON_UNESCAPED_SLASHES | JSON_UNESCAPED_UNICODE | JSON_THROW_ON_ERROR);
    }

    /** @return array<string,mixed> */
    private static function variant(Variant $v): array
    {
        return [
            'key' => $v->key,
            'codes' => array_map(self::codeString(...), $v->codes),
            'cnk' => self::cnk($v->cnk),
            'product' => self::productDecision($v->product),
            'attributes' => self::attributes($v->attributes),
            'categories' => array_map(self::codeString(...), $v->categories),
            'media' => array_map(self::media(...), $v->media),
            'substances' => array_map(self::substance(...), $v->substances),
            'descriptions' => array_map(self::description(...), $v->descriptions),
        ];
    }

    /** @param array{0: string, 1: string} $code */
    private static function codeString(array $code): string
    {
        return $code[0].':'.$code[1];
    }

    /**
     * @param array{canonical: array{0: string, 1: string}, aliases: list<array{0: string, 1: string}>}|null $cnk
     * @return array<string,mixed>|null
     */
    private static function cnk(?array $cnk): ?array
    {
        if ($cnk === null) {
            return null;
        }

        return [
            'canonical' => self::codeString($cnk['canonical']),
            'aliases' => array_map(self::codeString(...), $cnk['aliases']),
        ];
    }

    /** @return array<string,mixed> */
    private static function productDecision(Decision $p): array
    {
        return [
            'value' => self::productValue($p->value),
            'winner' => self::stringOrNull($p->winner),
            'status' => $p->status,
            'candidates' => array_map(
                static fn (array $c): array => [(string) $c[0], self::productValue($c[1])],
                $p->candidates
            ),
        ];
    }

    private static function productValue(mixed $value): mixed
    {
        // an int legacy entity passes through; a {scheme, value} tuple becomes "scheme:value".
        if (is_array($value)) {
            return $value[0].':'.$value[1];
        }

        return $value;
    }

    /** @return array<string,mixed> */
    private static function decision(Decision $d): array
    {
        return [
            'value' => $d->value,
            'winner' => self::stringOrNull($d->winner),
            'status' => $d->status,
            'candidates' => array_map(
                static fn (array $c): array => [(string) $c[0], $c[1]],
                $d->candidates
            ),
        ];
    }

    /**
     * @param list<array{0: string, 1: Decision}> $attrs
     * @return array<string, array<string,mixed>>
     */
    private static function attributes(array $attrs): array
    {
        $out = [];
        foreach ($attrs as [$field, $d]) {
            $out[$field] = self::decision($d);
        }

        return $out;
    }

    /**
     * @param array<string,mixed> $m
     * @return array<string,mixed>
     */
    private static function media(array $m): array
    {
        return [
            'asset' => (string) $m['asset'],
            'role' => (string) $m['role'],
            'source' => (string) $m['source'],
            'uri' => $m['uri'],
        ];
    }

    /**
     * @param array<string,mixed> $s
     * @return array<string,mixed>
     */
    private static function substance(array $s): array
    {
        return [
            'key' => (string) self::ownerString($s['key']),
            'codes' => array_map(self::codeString(...), $s['codes']),
            'sources' => array_map(static fn ($x): string => (string) $x, $s['sources']),
        ];
    }

    /**
     * @param array<string,mixed> $d
     * @return array<string,mixed>
     */
    private static function description(array $d): array
    {
        return [
            'key' => self::ownerString($d['key']),
            'via' => self::via($d['via']),
            'asserted_by' => array_map(static fn ($x): string => (string) $x, $d['asserted_by']),
            'attributes' => self::attributes($d['attributes']),
        ];
    }

    private static function via(mixed $via): string
    {
        if ($via === 'direct') {
            return 'direct';
        }
        // ['substance', key]
        return 'substance:'.self::ownerString($via[1]);
    }

    /** @param string|array{0: string, 1: string} $owner */
    private static function ownerString(string|array $owner): string
    {
        return is_array($owner) ? $owner[0].':'.$owner[1] : $owner;
    }

    private static function stringOrNull(mixed $v): ?string
    {
        return $v === null ? null : (string) $v;
    }

    /**
     * @param array<string, Placement> $legacyToKey
     * @return array<string, array<string,mixed>>
     */
    private static function xref(array $legacyToKey): array
    {
        $out = [];
        foreach ($legacyToKey as $entityKey => $placement) {
            $entity = self::decodeEntity($entityKey);
            $out[(string) $entity] = [
                'primary' => $placement->primary,
                'all' => $placement->all,
                'relation' => self::relation($placement->relation),
            ];
        }

        return $out;
    }

    private static function relation(mixed $relation): mixed
    {
        if ($relation === 'stable') {
            return 'stable';
        }
        if ($relation === 'split') {
            return 'split';
        }
        // ['merged', others] or ['merged', others, 'suspect']
        $others = array_map(static fn ($x): string => (string) $x, $relation[1]);
        if (isset($relation[2]) && $relation[2] === 'suspect') {
            return ['merged' => $others, 'suspect' => true];
        }

        return ['merged' => $others];
    }

    private static function decodeEntity(string $part): mixed
    {
        if (str_starts_with($part, 'i:')) {
            return (int) substr($part, 2);
        }

        return substr($part, 2);
    }

    private static function sort(mixed $value): mixed
    {
        if (is_array($value)) {
            if (array_is_list($value)) {
                return array_map(self::sort(...), $value);
            }
            ksort($value);

            return array_map(self::sort(...), $value);
        }

        return $value;
    }
}
