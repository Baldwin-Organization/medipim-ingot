defmodule GoldenRecord.Codes do
  @moduledoc """
  Code normalization & validation. The GTIN family (EAN-8 / UPC-12 / EAN-13 / GTIN-14) is ONE
  scheme at different widths: canonicalize to a 14-digit, zero-filled GTIN so equal trade items
  compare equal. Conservative — non-GTIN schemes and non-GTIN-length values pass through
  untouched, so it is safe to run over every ingested code.
  """
  @gtin_schemes [:gtin, :ean, :upc]

  # National short codes that medipim zero-pads to a fixed width. canonicalize left-pads an
  # all-digit value to the scheme's width so a query for "44813" matches a stored "0044813".
  # Real medipim data is already full-width, so padding is a no-op there.
  #
  # :cnk is DELIBERATELY EXCLUDED — real medipim cnk is always 7 digits (padding would be a no-op),
  # and ~10 existing tests use short fake cnk values ({:cnk,"0111"}/"0222"/"9"/"100"/"111"/"222"/
  # "555") that padding to 7 would silently break. (The design doc listed cnk:7; this exclusion is
  # a refinement after pre-dispatch verification.) Trim-only schemes (acl13, cip13, ndc, pdk, …)
  # are not listed — the default clause below trims them and that is all they need.
  @pad %{
    cip_acl7: 7,
    pzn: 8,
    pzn_austria: 7,
    sukl: 7,
    cefip: 7,
    national_code: 7,
    cn: 6
  }

  @doc "Canonical (scheme, value) for matching. GTIN family -> {:gtin, 14-digit zero-filled}."
  def canonicalize({scheme, value}) when scheme in @gtin_schemes do
    v = String.trim(value)
    if gtinish?(v), do: {:gtin, String.pad_leading(v, 14, "0")}, else: {scheme, v}
  end

  def canonicalize({scheme, value}) when is_map_key(@pad, scheme) do
    v = String.trim(value)
    width = Map.fetch!(@pad, scheme)

    if all_digits?(v) and String.length(v) < width,
      do: {scheme, String.pad_leading(v, width, "0")},
      else: {scheme, v}
  end

  def canonicalize({scheme, value}), do: {scheme, String.trim(value)}

  @doc "Do two codes denote the same thing once canonicalized? (8 vs zero-padded-12 vs 13 all equal)"
  def same?(a, b), do: canonicalize(a) == canonicalize(b)

  @doc "Mod-10 check-digit validity for a GTIN-family code."
  def valid_gtin?(code) do
    case canonicalize(code) do
      {:gtin, v} when byte_size(v) == 14 ->
        String.last(v) == Integer.to_string(check_digit(String.slice(v, 0, 13)))

      _ ->
        false
    end
  end

  @doc "GTIN-14 indicator digit: 0 = base unit, 1-8 = packaging levels, 9 = variable measure."
  def indicator(code) do
    case canonicalize(code) do
      {:gtin, v} when byte_size(v) == 14 -> v |> String.first() |> String.to_integer()
      _ -> nil
    end
  end

  @doc "Restricted-distribution / in-store GTIN (GS1 prefix 02 or 20-29) — NOT globally unique."
  def restricted?(code) do
    case canonicalize(code) do
      {:gtin, v} when byte_size(v) == 14 ->
        prefix = String.slice(v, 1, 2)
        prefix == "02" or (prefix >= "20" and prefix <= "29")

      _ ->
        false
    end
  end

  # ── bridge grade — an ORTHOGONAL axis over the engine SCHEME ATOM (gr-ose) ─────
  #
  # Engine vocabulary (GH #56): what a grade MEANS lives here; the ingest registry owns only the
  # medipim-field→scheme mapping and delegates back. A SECOND, independent classification used by
  # the over-merge guard: when a merge clusters two legacy entities, is the shared bridge a
  # NATIONAL identity code (trusted — the re-derivation working as intended) or merely a
  # reusable/reassignable BARCODE/GS1 code (suspect — medipim flags such ambiguous matches as
  # ProductCodeIdentityMatch / MED-11207)? Keyed on the engine scheme atom, and DELIBERATELY
  # distinct from the registry's `classification/1`: acl13 and cip13 stay `:identity` there (they
  # DO bridge in clustering) yet are barcode-grade here.
  @national_schemes MapSet.new([
                      :cnk,
                      :cip_acl7,
                      :cefip,
                      :pzn,
                      :pzn_austria,
                      :sukl,
                      :national_code,
                      :cn,
                      :pdk,
                      :ndc,
                      :hri,
                      :pin,
                      :lppr,
                      :fred,
                      :zcode,
                      # ISBNs are registration-agency-assigned once per title/format (ISO 2108),
                      # never reissued the way GS1 barcodes are — a trusted bridge (gr-vgb).
                      :isbn13,
                      :isbn10
                    ])

  @barcode_schemes MapSet.new([:gtin, :acl13, :cip13])

  # schemes that identify a *supplier's* reference, not a globally-unique product — never bridge.
  # :artg_id (gr-sx7.1): one AU ARTG registration covers many pack sizes (3,807 live ARTG numbers
  # sit on >1 entity), so it is an identity code carried like a restricted GTIN — shared, no fuse.
  @non_bridging_schemes MapSet.new([:mpn, :supplier_ref, :artg_id])

  @doc """
  Bridge grade of an ENGINE SCHEME ATOM — the over-merge guard's axis (gr-ose):

    * `:national` — a national identity code (cnk, cip_acl7, …); a merge sharing one is TRUSTED.
    * `:barcode`  — a reusable/reassignable GS1/barcode code (gtin, acl13, cip13); a merge bridged
                    SOLELY by one of these is SUSPECT.
    * `:none`     — anything else (external_ref / attribute / unknown) — not a bridge.
  """
  def bridge_grade(scheme) do
    cond do
      MapSet.member?(@national_schemes, scheme) -> :national
      MapSet.member?(@barcode_schemes, scheme) -> :barcode
      true -> :none
    end
  end

  @doc "Is this engine scheme atom a national identity code (trusted bridge)?"
  def national_grade?(scheme), do: bridge_grade(scheme) == :national

  @doc "Is this engine scheme atom a GS1/barcode code (suspect bridge)?"
  def barcode_grade?(scheme), do: bridge_grade(scheme) == :barcode

  @doc "May this code never bridge two products? Restricted GTINs and non-bridging schemes."
  def shared?({scheme, _} = code),
    do: restricted?(code) or MapSet.member?(@non_bridging_schemes, scheme)

  defp gtinish?(v), do: v =~ ~r/^\d+$/ and String.length(v) in [8, 12, 13, 14]

  defp all_digits?(v), do: v != "" and v =~ ~r/^\d+$/

  # GS1 mod-10 check digit. Public (@doc false) as THE one implementation — Isbn shares it.
  @doc false
  def check_digit(payload) do
    sum =
      payload
      |> String.graphemes()
      |> Enum.map(&String.to_integer/1)
      |> Enum.reverse()
      |> Enum.with_index()
      |> Enum.reduce(0, fn {d, i}, acc -> acc + d * if(rem(i, 2) == 0, do: 3, else: 1) end)

    rem(10 - rem(sum, 10), 10)
  end
end
