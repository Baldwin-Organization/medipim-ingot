# test/ingest/medipim_fr_347025_test.exs — FR re-derivation for real legacy entity 347025.
#
#   Run:  mix test
#
# The Belgian companion to rederive_test.exs's 422156: a real French extract (entity 347025, a
# Biotherm face-care product, cbId 52549) carrying the FR identity schemes — cipOrAcl7 (-> :cip_acl7),
# acl13, and the EAN/eanGtin family — with NO cnk. It exercises the gr-6k4 registry end-to-end:
# French codes canonicalize and bridge, the eanGtin13_/eanGtin14_ value-prefix migration decodes,
# op-4 source-in-value deletes delist whole listings, yet identity re-derives to ONE product.
#
# Across its 5 source orgs the history is busy (32 identity events, set/add/remove/delete, several
# orgs fully delisted by op-4 by the end), but every surviving listing shares cipOrAcl7 4440813
# and/or acl13 3401344408137 — so this is the single-entity `:stable` analog of 422156: one cluster,
# one surrogate key, one golden product. (The cross-entity over-merge cases are gr-ose's concern.)

alias GoldenRecord.{Events, Codes, Api, PublicId}

defmodule MedipimFr347025Test do
  use ExUnit.Case, async: true

  @fixture Path.join(__DIR__, "fixtures/medipim_fr_347025.json")

  # the canonical French identity the data converges on.
  @cip_acl7 {:cip_acl7, "4440813"}
  @acl13 {:acl13, "3401344408137"}
  @gtin Codes.canonicalize({:gtin, "3367729203738"})

  defp identity_events(log), do: Enum.reject(log, &match?(%Events.ClaimAsserted{}, &1))

  setup do
    {:ok, env} = HistoryEnvelope.load(@fixture)
    %{env: env}
  end

  describe "the decoded French envelope" do
    test "is medipim-fr / entity 347025, with FR identity codes and no media", %{env: env} do
      assert env.source_system == "medipim-fr"
      assert env.legacy_entity == 347_025

      # the eanGtin13_/eanGtin14_ value-prefix was stripped at decode (generic {field}_ strip).
      schemes =
        env.events
        |> Enum.filter(&(&1.kind == :identity))
        |> Enum.map(& &1.data.scheme)
        |> Enum.uniq()
        |> Enum.sort()

      assert schemes == ~w(acl13 cipOrAcl7 ean eanGtin13 eanGtin14 gtin)
      refute Enum.any?(env.events, &(&1.data[:code] && String.contains?(to_string(&1.data.code), "eanGtin")))

      # purely a French extract — no Belgian CNK rides along.
      refute Enum.any?(env.events, &(&1.kind == :identity and &1.data.scheme == "cnk"))
    end
  end

  describe "re-derivation of entity 347025" do
    test "all surviving listings re-derive to exactly ONE surrogate key", %{env: env} do
      result = Rederivation.run([env], 1)

      # one cluster, one SK — the single-entity :stable outcome (the analog of 422156).
      assert [_only] = result.clusters
      assert [{"SK_1", codes}] = Map.to_list(result.ledger.members)

      # the canonical French identity the orgs converge on: cip_acl7, acl13, and the EAN GTIN.
      assert MapSet.member?(codes, @cip_acl7)
      assert MapSet.member?(codes, @acl13)
      assert MapSet.member?(codes, @gtin)
    end

    test "every converging code resolves to the one key, with no collisions", %{env: env} do
      %{log: log} = Rederivation.run([env], 1)

      assert Api.resolve_key(log, @cip_acl7) == "SK_1"
      assert Api.resolve_key(log, @acl13) == "SK_1"
      assert Api.resolve_key(log, @gtin) == "SK_1"
      # the raw 13-digit EAN canonicalizes to the same GTIN-14 member and still resolves.
      assert Api.resolve_key(log, {:gtin, "3367729203738"}) == "SK_1"

      # cip_acl7 is identity-grade and owns exactly one key — no collision across the orgs.
      assert PublicId.collisions(:cip_acl7, log) == []
      assert PublicId.collisions(:acl13, log) == []
    end

    test "identity events are stamped to continue after the max claim order", %{env: env} do
      %{log: log} = Rederivation.run([env], 1)

      max_claim_order =
        log |> Enum.filter(&match?(%Events.ClaimAsserted{}, &1)) |> Enum.map(& &1.order) |> Enum.max()

      ident = identity_events(log)

      assert ident != []
      assert Enum.all?(ident, &(&1.order > max_claim_order))
      assert Api.changes_since(log, max_claim_order) == ident
    end
  end
end
