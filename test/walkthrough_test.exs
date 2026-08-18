# test/walkthrough_test.exs — a guided tour of the golden-record model.
#
#   Run:  mix test test/walkthrough_test.exs
#
# Read top to bottom. Many sources each make claims about products; the engine
# answers one question: which claims describe the SAME real product? Identity is
# re-derived from the CODES a source carries — never from who the source is, and
# never from a legacy grouping.
#
#   Part 1 builds the model from first principles — no medipim, no legacy.
#   Part 2 shows the legacy medipim history is just one more source of claims.
#
# (This is the executable spec for bead gr-ccf. The Part-2 French scenario was the
#  RED TARGET — it is green since gr-6k4 taught the engine the French codes.)

alias GoldenRecord.{Events, Substrate, Priority, Cluster, IdentityLedger, Catalog, History}

defmodule WalkthroughTest do
  use ExUnit.Case, async: true
  import Substrate, only: [claim: 5]

  @t ~D[2026-01-01]

  # Source trust for survivorship: a manufacturer outranks a supplier by default;
  # for :color the two are equal, so a disagreement is honestly left undecided.
  @priority Priority.new(%{color: [[:supplier, :manufacturer]]}, [[:manufacturer], [:supplier]])

  # ── helpers — say it in the domain, not the plumbing ──────────────────────

  # A source's LISTING: the identity codes it carries, plus optional attributes
  # (`attrs: [name: "…"]`) and an optional product label (`product: "…"`).
  defp listing(source, codes, opts \\ []) do
    attrs =
      for {field, value} <- Keyword.get(opts, :attrs, []),
          do: claim(source, :attribute, %{code: hd(codes), field: field, value: value}, @t, @t)

    grouping =
      for product <- List.wrap(opts[:product]),
          code <- codes,
          do: claim(source, :grouping, %{code: code, product: product}, @t, @t)

    # ref keys this source's listing — distinct per (source, primary code) so two
    # listings from one source are two listings, not one overwriting the other.
    ref = "#{source}/#{elem(hd(codes), 1)}"
    [claim(source, :identity, %{ref: ref, codes: codes}, @t, @t) | attrs ++ grouping]
  end

  # Re-derive identities from a pile of claims and return today's golden products.
  defp golden(claims) do
    log = Enum.map(Enum.with_index(claims), fn {c, i} -> %{c | order: i} end)

    minted =
      IdentityLedger.decide(IdentityLedger.new(), {:reconcile, Cluster.variants(Substrate.current(log)), @t})

    History.now(log ++ minted, @priority)
  end

  defp variants(golden), do: Enum.flat_map(golden, & &1.variants)
  defp field(variant, name), do: variant.attributes |> List.keyfind(name, 0) |> elem(1)

  # ════════════════════════════════════════════════════════════════════════
  #  PART 1 — what a product and a variant ARE (built from nothing)
  # ════════════════════════════════════════════════════════════════════════

  describe "a VARIANT is one re-derived identity" do
    # A variant is a cluster of identity codes that denote the same trade item.
    # Sources are fused by their codes — the engine never trusts who said it.

    test "two sources carrying the same code describe ONE variant" do
      golden =
        golden(
          listing(:supplier, [{:cnk, "3612173"}]) ++
            listing(:manufacturer, [{:cnk, "3612173"}, {:ean, "5012345678900"}])
        )

      assert [variant] = variants(golden)
      assert {:cnk, "3612173"} in variant.codes
      # the EAN-13 the manufacturer added rides on the same variant, canonicalised to a GTIN-14
      assert {:gtin, "05012345678900"} in variant.codes
    end

    test "two sources that share NO code are NOT merged — two variants stand apart" do
      golden =
        golden(
          listing(:supplier, [{:gtin, "05012345678900"}]) ++
            listing(:manufacturer, [{:gtin, "15012345678907"}])
        )

      # same item body, different GS1 indicator => different trade items => no merge
      assert length(variants(golden)) == 2
    end
  end

  describe "a PRODUCT groups the variants that belong together" do
    # Identity (a variant) is re-derived from codes; a PRODUCT is the set of
    # variants tied together by a grouping label (here, a manufacturer's name).

    test "two pack sizes are two variants of one product" do
      [product] =
        golden(
          listing(:manufacturer, [{:gtin, "05012345678900"}], product: "ADERMA-GEL") ++
            listing(:manufacturer, [{:gtin, "15012345678907"}], product: "ADERMA-GEL")
        )

      assert product.product == "ADERMA-GEL"
      assert length(product.variants) == 2
    end
  end

  describe "combining sources resolves a field by SURVIVORSHIP" do
    test "the higher-priority source wins a contradicted field" do
      [product] =
        golden(
          listing(:supplier, [{:gtin, "05012345678900"}], attrs: [name: "gel 750ml"]) ++
            listing(:manufacturer, [{:gtin, "05012345678900"}], attrs: [name: "Aderma Gel 750ml"])
        )

      [variant] = product.variants
      assert field(variant, :name).value == "Aderma Gel 750ml"
      assert field(variant, :name).winner == :manufacturer
    end

    test "an unbreakable tie among equals is left for a steward, not guessed" do
      [product] =
        golden(
          listing(:supplier, [{:gtin, "05012345678900"}], attrs: [color: "red"]) ++
            listing(:manufacturer, [{:gtin, "05012345678900"}], attrs: [color: "blue"])
        )

      [variant] = product.variants
      assert field(variant, :color).status == :needs_review
    end
  end

  describe "a COLLISION is surfaced, never silently resolved" do
    test "one code claimed for two different products is flagged needs_review" do
      [product] =
        golden(
          listing(:supplier, [{:gtin, "05012345678900"}], product: "ALPHA") ++
            listing(:manufacturer, [{:gtin, "05012345678900"}], product: "BETA")
        )

      [variant] = product.variants
      assert variant.product.status == :needs_review
    end
  end

  # ════════════════════════════════════════════════════════════════════════
  #  PART 2 — the legacy medipim history is just ONE more source
  # ════════════════════════════════════════════════════════════════════════
  #
  # A legacy entity's history arrives as a HistoryEnvelope. The ingest folds it
  # into the SAME claims, re-derives identity, and projects the SAME shape — the
  # legacy `entity` is carried only as the product label, never as identity.
  # (Envelope timestamps are integer epochs, so we project with Catalog.project
  #  directly — History.now is date-based.)

  @legacy_at 1_700_000_000

  defp golden_from_legacy(envelopes) do
    %{log: log, ledger: ledger} = Rederivation.run(envelopes, @legacy_at)
    live = for(%Events.ClaimAsserted{} = c <- log, do: c) |> Substrate.current()
    Catalog.project(ledger.members, live, @priority, %{attr: %{}, product: %{}})
  end

  describe "Part 2 — legacy history as one input" do
    @fixture Path.join(__DIR__, "ingest/fixtures/medipim_be_422156.json")

    test "the real 422156 envelope yields the SAME product + variant shape" do
      [product] = golden_from_legacy([HistoryEnvelope.load!(@fixture)])

      assert product.product == 422_156
      assert [variant] = product.variants
      assert {:cnk, "3612173"} in variant.codes
    end

    # Was the RED TARGET — green since gr-6k4 (code registry) taught the engine the
    # French schemes (cipOrAcl7 -> :cip_acl7 padded to 7; acl13 -> :acl13).
    test "a French listing's cipOrAcl7 + acl13 canonicalise and cluster into one variant" do
      {:ok, env} =
        HistoryEnvelope.from_map(%{
          "schema_version" => "1",
          "legacy_entity" => 347_025,
          "events" => [
            %{
              "recorded_at" => 1,
              "source" => "2",
              "op" => "set",
              "kind" => "identity",
              "scheme" => "cipOrAcl7",
              "code" => "4440813"
            },
            %{
              "recorded_at" => 2,
              "source" => "2",
              "op" => "set",
              "kind" => "identity",
              "scheme" => "acl13",
              "code" => "3401344408137"
            }
          ]
        })

      %{ledger: ledger} = Rederivation.run([env], @legacy_at)
      [codes] = Map.values(ledger.members)

      assert {:cip_acl7, "4440813"} in codes
      assert {:acl13, "3401344408137"} in codes
    end
  end
end
