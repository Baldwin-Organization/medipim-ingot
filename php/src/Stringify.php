<?php

declare(strict_types=1);

namespace Ingot;

/**
 * Elixir's `Kernel.to_string/1` over JSON-decoded values — the ONE shared port (it was
 * hand-rolled in both ClaimMapping and EnvelopeDecoder, and the copies had started to drift).
 *
 * A list is an iolist/charlist: integers are bytes (codepoints), strings and nested lists
 * concatenate. Booleans print as their atom names.
 */
final class Stringify
{
    public static function value(mixed $v): string
    {
        if (is_bool($v)) {
            return $v ? 'true' : 'false';
        }
        if (is_array($v)) {
            $out = '';
            foreach ($v as $part) {
                $out .= is_int($part) ? mb_chr($part, 'UTF-8') : self::value($part);
            }

            return $out;
        }

        return (string) $v;
    }
}
