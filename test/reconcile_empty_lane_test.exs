# reconcile_empty_lane_test.exs — pins the DELIBERATE divergence between the two per-lane
# reconcile loops (gr-huw). Same skeleton, opposite empty-lane semantics, both load-bearing:
#
#   * Lanes.reconcile folds an append-only, possibly PARTIAL claim stream. A lane with no
#     identity claims means "no information" — SKIP, members persist. This is what protects
#     steward-authored description/media records when a live batch only speaks about products.
#   * History.reconcile_temporal replays the COMPLETE claim set effective at a boundary. A lane
#     with no clusters means "nothing is effective" — decide runs and RETRACTS, which is what
#     drops a product from as-of projections after its validity window closes.
#
# If one of these tests breaks because the behaviors were "unified", that is the bug.
defmodule ReconcileEmptyLaneTest do
  use ExUnit.Case, async: true

  import Substrate, only: [claim: 5]

  @d1 ~D[2026-01-10]
  @d2 ~D[2026-02-01]

  defp timestamp(date), do: DateTime.new!(date, ~T[12:00:00], "Etc/UTC")

  test "Lanes.reconcile SKIPS a lane with no identity claims — absence of evidence" do
    # A steward-authored description exists in its own lane.
    desc = %{claim(:steward, :identity, %{ref: "D1", codes: [{:text_id, "D1"}]}, @d1, @d1) | order: 1}

    {_events, ledgers} =
      Lanes.reconcile(Substrate.current([desc]), MapSet.new(), Lanes.new_ledgers(), @d1)

    assert map_size(ledgers.description.members) == 1

    # A later batch speaks ONLY about the product lane (a live delta touching one lane).
    product = %{claim(:supplier, :identity, %{ref: "A", codes: [{:cnk, "0111"}]}, @d2, @d2) | order: 2}

    {events, after_ledgers} =
      Lanes.reconcile(Substrate.current([product]), MapSet.new(), ledgers, @d2)

    # The untouched description lane persists — no events for it, no retraction.
    assert after_ledgers.description == ledgers.description
    refute Enum.any?(events, &match?(%Events.IdentityRetracted{}, &1))
    assert Enum.any?(events, &match?(%Events.IdentityMinted{}, &1))
  end

  test "History's bitemporal replay RETRACTS a lane whose claims all expired — evidence of absence" do
    # One source record, valid Jan 1 .. Mar 31 (a license window that closes).
    revision = %Events.SourceRecordRevised{
      source: "supplier",
      ref: "P-1",
      revision: 1,
      operation: :upsert,
      active: true,
      claims: [
        claim(
          "supplier",
          :identity,
          %{ref: "P-1", codes: [{:cnk, "1000001"}]},
          ~D[2026-01-01],
          ~D[2026-01-01]
        )
      ],
      fingerprint: 1,
      valid_from: ~D[2026-01-01],
      valid_to: ~D[2026-03-31],
      recorded_at: timestamp(~D[2026-01-01]),
      order: 1
    }

    known_at = timestamp(~D[2026-05-01])

    # Inside the window the key exists…
    assert Map.keys(History.state_bitemporal([revision], known_at, ~D[2026-02-15]).members) == ["SK_1"]

    # …after it closes, the key is retracted: no zombie product in as-of projections.
    assert History.state_bitemporal([revision], known_at, ~D[2026-04-15]).members == %{}
  end
end
