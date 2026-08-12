# test/ingest/golden_records_test.exs — ExUnit for the golden-record projection (bead gr-8r6).
#
#   Run:  mix test
#
# Drives the real 422156 fixture end-to-end (load → Rederivation.run → GoldenRecords.project) and
# asserts the projected golden record: ONE product, ONE variant (SK_1), the convergent codes +
# CNK canonical, and real attribute values folded from the fixture's events. Confirms NO
# Date/FunctionClause crash (i.e. Catalog.project is used, not History.now). Plus two synthetic
# survivorship cases: a multi-source disagreement surfaces :needs_review under the permissive
# default, and resolves to the ranked winner when a Priority is supplied. Mirrors
# rederive_test.exs / claim_mapping_test.exs conventions (terse synthetic-envelope helpers).

defmodule GoldenRecordsTest do
  use ExUnit.Case, async: true

  @fixture Path.join(__DIR__, "fixtures/medipim_be_422156.json")

  # ── helpers (same shape as rederive_test.exs) ───────────────────────────────
  defp envelope(entity, events) do
    {:ok, env} =
      HistoryEnvelope.from_map(%{
        "schema_version" => "1",
        "legacy_entity" => entity,
        "events" => events
      })

    env
  end

  defp id(source, op, scheme, code, at),
    do: %{
      "recorded_at" => at,
      "source" => source,
      "op" => op,
      "kind" => "identity",
      "scheme" => scheme,
      "code" => code
    }

  defp attr(source, field, value, at),
    do: %{
      "recorded_at" => at,
      "source" => source,
      "op" => "set",
      "kind" => "attribute",
      "field" => field,
      "value" => value
    }

  # Pull a single field's survivorship decision out of a variant's [{field, decision}] list.
  defp field(variant, name), do: variant.attributes |> Enum.into(%{}) |> Map.fetch!(name)

  # ── the real 422156 fixture (acceptance) ─────────────────────────────────────
  describe "real entity 422156" do
    setup do
      {:ok, env} = HistoryEnvelope.load(@fixture)
      # No Date/FunctionClause crash here proves Catalog.project (Date-free) is used, not History.now
      # (which would raise Date.compare/2 on the fixture's INTEGER epoch timestamps).
      %{gr: env |> List.wrap() |> Rederivation.run(1) |> GoldenRecords.project()}
    end

    test "projects exactly ONE product with ONE variant keyed SK_1", %{gr: gr} do
      assert [%{product: 422_156, variants: [variant]}] = gr.records
      assert variant.key == "SK_1"
    end

    test "the variant's codes include canonical CNK + the canonical GTIN", %{gr: gr} do
      [%{variants: [variant]}] = gr.records
      codes = MapSet.new(variant.codes)

      # canonical CNK — confirmed against Codes.canonicalize, never hard-coded.
      assert MapSet.member?(codes, Codes.canonicalize({:cnk, "3612173"}))
      # the convergent GTIN, canonicalized (the fixture also carries its un-padded EAN-13 width).
      assert MapSet.member?(codes, Codes.canonicalize({:gtin, "03282770146004"}))
      assert MapSet.member?(codes, Codes.canonicalize({:gtin, "3282770146004"}))
    end

    test "the variant's CNK canonical is {:cnk, \"3612173\"} with no alias", %{gr: gr} do
      [%{variants: [variant]}] = gr.records
      assert variant.cnk == %{canonical: Codes.canonicalize({:cnk, "3612173"}), aliases: []}
    end

    test "attributes reflect the fixture without inventing winners for conflicting names", %{gr: gr} do
      [%{variants: [variant]}] = gr.records

      # A resolved, single-source field straight from the fixture's import_871 events.
      assert %{value: "cosmetics", status: :resolved} = field(variant, "apbCategory")
      assert %{value: "active", status: :resolved} = field(variant, "status")

      # The two equally-ranked sources disagree only in spelling/spacing. Keep both candidates and
      # publish no arbitrary canonical spelling until policy or a steward resolves it.
      assert %{
               value: nil,
               winner: nil,
               status: :needs_review,
               candidates: [
                 {"1034", "Aderma Primalba Gel Lavant 2en1 750ml"},
                 {"1035", "ADERMA PRIMALBA GEL LAVANT 2EN1 750 ML"}
               ]
             } = field(variant, "name:fr")

      assert %{
               value: nil,
               winner: nil,
               status: :needs_review,
               candidates: [
                 {"1034", "Aderma Primalba Wasgel 2in1 750ml"},
                 {"1035", "ADERMA PRIMALBA WASGEL 2IN1 750 ML"}
               ]
             } = field(variant, "name:nl")
    end

    test "media carries the depicted media-lane records via :depicts edges (gr-kek)", %{gr: gr} do
      [%{variants: [variant]}] = gr.records
      assert variant.media != []
      assert Enum.all?(variant.media, &String.starts_with?(&1.asset, "MED_"))
    end

    test "the pass-through log still folds through the engine's read layer", %{gr: gr} do
      # Date-free engine entrypoints remain usable on the projected log.
      assert Api.resolve_key(gr.log, {:cnk, "3612173"}) == "SK_1"
      assert PublicId.collisions(:cnk, gr.log) == []
    end
  end

  # ── survivorship does real work (synthetic) ──────────────────────────────────
  describe "survivorship under priority" do
    # Same product (shared CNK), two sources disagree on one attribute.
    defp two_source_conflict do
      [
        envelope(1, [id("A", "set", "cnk", "555", 10), attr("A", "name", "Alpha", 11)]),
        envelope(1, [id("B", "set", "cnk", "555", 10), attr("B", "name", "Beta", 12)])
      ]
    end

    test "permissive default surfaces a multi-source conflict as :needs_review" do
      gr = two_source_conflict() |> Rederivation.run(1) |> GoldenRecords.project()

      assert [%{variants: [variant]}] = gr.records
      assert %{status: :needs_review} = field(variant, "name")
    end

    test "a supplied priority resolves the conflict to the ranked winner" do
      priority = Priority.new(%{}, [["A"], ["B"]])
      gr = two_source_conflict() |> Rederivation.run(1) |> GoldenRecords.project(priority)

      assert [%{variants: [variant]}] = gr.records
      assert %{value: "Alpha", winner: "A", status: :resolved} = field(variant, "name")
    end

    # gr-6y2 slice 2: the injected-policy toggle must be reachable from the FOLD ENTRY, not just
    # Survivorship.decide/3. A 2-arity rank fun (NOT a %Priority{}) threads through project/2 →
    # Catalog.project, and the same claims under different injected context yield different winners —
    # exactly what one static Priority cannot express.
    test "an injected policy fn reaches the fold entry and its context picks the winner" do
      prefer = fn preferred -> fn _dim, src -> if src == preferred, do: 0, else: 1 end end

      gr_b = two_source_conflict() |> Rederivation.run(1) |> GoldenRecords.project(prefer.("B"))
      assert [%{variants: [v_b]}] = gr_b.records
      assert %{value: "Beta", winner: "B", status: :resolved} = field(v_b, "name")

      gr_a = two_source_conflict() |> Rederivation.run(1) |> GoldenRecords.project(prefer.("A"))
      assert [%{variants: [v_a]}] = gr_a.records
      assert %{value: "Alpha", winner: "A", status: :resolved} = field(v_a, "name")
    end
  end
end
