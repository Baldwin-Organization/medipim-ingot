# lib/ingest/isbn.ex — ISBN canonicalization + checksums for the books vertical (gr-vgb).
#
# The genericity gate's INGEST-SIDE half of the scheme registry: the engine's normalizer
# vocabulary (trim / pad_left / gtin — see contract/scheme_registry.schema.json) cannot express
# the ISBN-10 → ISBN-13 transform (it needs mod-11 validation and a recomputed GS1 check digit),
# so per the books scheme declaration (test/ingest/fixtures/books/scheme_registry.json) the
# ADAPTER canonicalizes every ISBN to ISBN-13 before submission, exactly like the GTIN family
# folds ean/upc spellings to gtin — equivalence at the mapping seam, zero engine changes.
#
# An ISBN-13 IS a Bookland EAN-13 (GS1 prefix 978/979), so its check digit is the engine's
# existing GS1 mod-10 (`Codes.valid_gtin?/1` — used read-only here). ISBN-10 carries its own
# mod-11 check digit (X = 10, final position only). Only 978-prefixed ISBN-13s have an ISBN-10
# form; 979 titles are 13-only.

alias GoldenRecord.{Codes}

defmodule Isbn do
  @moduledoc """
  ISBN checksum validation and canonicalization to ISBN-13 (`docs/CLAIMS_CONTRACT.md`'s
  equivalence-family semantics, applied at the mapping seam).

  `to_isbn13/1` accepts a hyphenated/spaced ISBN-10 or ISBN-13, validates its check digit
  (mod-11 for ISBN-10, GS1 mod-10 for ISBN-13 — the Bookland EAN check the engine already
  implements), and answers the canonical 13-digit form. `code/1` formats it as the wire's
  `"isbn13:<digits>"` code string.
  """

  @doc """
  Canonicalize a raw ISBN to its ISBN-13 digits: `{:ok, "978…"} | {:error, reason}`.
  Strips hyphens/spaces; an ISBN-10 must pass mod-11 (then converts via the 978 prefix and a
  recomputed GS1 check digit); an ISBN-13 must begin 978/979 and pass GS1 mod-10.
  """
  def to_isbn13(raw) when is_binary(raw) do
    digits = raw |> String.replace(["-", " "], "") |> String.upcase()

    cond do
      isbn10_shaped?(digits) ->
        if valid_isbn10?(digits),
          do: {:ok, convert_10_to_13(digits)},
          else: {:error, "#{inspect(raw)} fails the ISBN-10 mod-11 check digit"}

      isbn13_shaped?(digits) ->
        cond do
          not String.starts_with?(digits, ["978", "979"]) ->
            {:error, "#{inspect(raw)} is not Bookland (an ISBN-13 begins 978 or 979)"}

          not Codes.valid_gtin?({:ean, digits}) ->
            {:error, "#{inspect(raw)} fails the ISBN-13 (GS1 mod-10) check digit"}

          true ->
            {:ok, digits}
        end

      true ->
        {:error, "#{inspect(raw)} is not ISBN-shaped (10 or 13 characters after hyphens)"}
    end
  end

  @doc "Does this raw string carry a checksum-valid ISBN (either width)?"
  def valid?(raw) when is_binary(raw), do: match?({:ok, _}, to_isbn13(raw))

  @doc ~s(The canonical wire code for a raw ISBN: `{:ok, "isbn13:978…"} | {:error, reason}`.)
  def code(raw) do
    with {:ok, digits} <- to_isbn13(raw), do: {:ok, "isbn13:" <> digits}
  end

  # ── shapes ──────────────────────────────────────────────────────────────────
  # ISBN-10: nine digits + a mod-11 check digit that may be X. ISBN-13: thirteen digits.
  defp isbn10_shaped?(d), do: d =~ ~r/^\d{9}[\dX]$/
  defp isbn13_shaped?(d), do: d =~ ~r/^\d{13}$/

  # ── ISBN-10 mod-11 ──────────────────────────────────────────────────────────
  defp valid_isbn10?(digits) do
    sum =
      digits
      |> String.graphemes()
      |> Enum.with_index()
      |> Enum.reduce(0, fn {ch, i}, acc -> acc + digit_value(ch) * (10 - i) end)

    rem(sum, 11) == 0
  end

  defp digit_value("X"), do: 10
  defp digit_value(ch), do: String.to_integer(ch)

  # Drop the mod-11 check digit, prepend the 978 Bookland prefix, recompute GS1 mod-10.
  defp convert_10_to_13(digits) do
    payload = "978" <> String.slice(digits, 0, 9)
    payload <> gs1_check_digit(payload)
  end

  defp gs1_check_digit(payload), do: Integer.to_string(Codes.check_digit(payload))
end
