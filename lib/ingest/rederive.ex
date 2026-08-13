# lib/ingest/rederive.ex — cluster + reconcile the legacy claims into surrogate keys (gr-chq).
#
# Stage 3 of the legacy-medipim ingest, after envelope_loader (gr-n8i) and claim_mapping (gr-beo).
# Per the design (docs/plans/2026-06-05-legacy-history-ingest-design.md, "Ingest pipeline" step 4):
# re-derive identity from the codes themselves — the legacy `entity` is NEVER a clustering input,
# it rides along only as the :grouping claims ClaimMapping already synthesized.
#
# The flow is the loop proven verbatim in claim_mapping_test.exs and every demo:
#
#     live     = Substrate.current(claims)
#     clusters = Cluster.variants(live, shared)   # shared codes are members but never bridge
#     events   = IdentityLedger.decide(IdentityLedger.new(), {:reconcile, clusters, shared, at})
#     ledger   = Enum.reduce(events, IdentityLedger.new(), &IdentityLedger.evolve(&2, &1))
#
# OUTPUT — the re-derived EVENT LOG = `claims ++ identity_events`. The engine's entire read layer
# (Api / PublicId / History) folds a SINGLE time-ordered `log` that holds BOTH the
# %Events.ClaimAsserted{} claims AND the identity events `decide` emits, so this log is foldable
# UNCHANGED by Api.resolve_key/lookup, PublicId.canonical/collisions, History.now, etc. The claims
# are already `order`-stamped by ClaimMapping; we stamp the identity events to CONTINUE after the
# max claim order so Api.changes_since/2 (the cursor-based change feed) sees them in sequence —
# mirroring how the engine sequences a real go-forward log.
#
# SCOPE: this bead produces ONLY the intermediate artifact (log + ledger). It BLOCKS two beads and
# does NOT do their work — gr-0c2 = LegacyXref (legacy ⟷ SK map + relation :stable/:split/:merged),
# gr-8r6 = the golden-record projection (Catalog/Api output). No xref, no relation, no projection.

defmodule Rederivation do
  @doc """
  Re-derive identity from raw `%HistoryEnvelope{}`s at instant `at`. Builds claims via
  `ClaimMapping.build/1`, then clusters + reconciles into surrogate keys.

  Returns `%{log: [...], ledger: %IdentityLedger{}, clusters: [MapSet], shared: MapSet}`, where
  `log` is the re-derived event log (claims ++ stamped identity events) — foldable as-is by the
  engine's read layer.
  """
  def run(envelopes, at) when is_list(envelopes) do
    envelopes |> ClaimMapping.build() |> from_claims(at)
  end

  @doc """
  Like `run/2` but takes an already-built `%{claims, shared}` map (the output of
  `ClaimMapping.build/1`) directly — for callers that fold envelopes once and reuse the claims.
  """
  def from_claims(%{claims: claims, shared: shared}, at) do
    live = Substrate.current(claims)

    # Per-lane reconcile (gr-2a8): each entity lane clusters against its own ledger, minting
    # under its own prefix (SK/SUB/DSC/MED). `clusters` and `ledger` keep their historical,
    # product-lane meaning for existing callers; `ledgers` is the full per-lane map.
    {lane_events, ledgers} = Lanes.reconcile(live, shared, Lanes.new_ledgers(), at)
    identity_events = stamp(lane_events, claims)

    ledger = Enum.reduce(identity_events, IdentityLedger.new(), &IdentityLedger.evolve(&2, &1))
    clusters = Cluster.variants(Lanes.identity_claims(live, :product), shared)

    %{log: claims ++ identity_events, ledger: ledger, ledgers: ledgers, clusters: clusters, shared: shared}
  end

  # Continue the identity events' `:order` after the highest claim order, preserving decide's
  # emission order, so the combined log stays monotonically sequenced for Api.changes_since/2.
  # Public (@doc false) as THE one stamping helper — Temporal.run and FinerClaims.run share it.
  @doc false
  def stamp(events, claims) do
    base = claims |> Enum.map(& &1.order) |> Enum.max(fn -> -1 end)

    events
    |> Enum.with_index(base + 1)
    |> Enum.map(fn {event, order} -> %{event | order: order} end)
  end
end
