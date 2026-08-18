# test/survivorship_parity_spike_test.exs — SPIKE for gr-vu8 (GO/NO-GO).
#
# Question: can the engine's Priority/Survivorship reproduce medipim's SourcesRanker
# (src/Baldpim/Domain/Product/WriteModel/SourcesRanker.php)?
#
# SourcesRanker, decomposed:
#   getPreferredSourceForFieldFromSources(field, sources, productOrgs):
#     - each FIELD carries a score map  field->getSourceScores() : (sysId | orgId) => int
#     - a source's score is resolved by its sysId (org group) first, then its orgId, else default 0
#     - PENALTY: a non-system source NOT present on the product's orgs is devalued to -1
#       (so it loses to any default-0 source). i.e. the score depends on the PRODUCT CONTEXT.
#     - highest score wins; equal scores break by source-array order (the >= in
#       isSourceOneBetterThanSourceTwo).
#
# Engine model (lib/golden_record_core.ex):
#   Priority{table: dimension => tiers, default}; rank(dim, source) = index of the tier holding
#   source (lower = better) or :infinity. Survivorship.decide picks the lowest-rank source; an
#   equal-top-rank tie with differing values => :needs_review.
#
# VERDICT (asserted below): CONDITIONAL GO.
#   [1] per-field cardinal scores -> ordinal tiers: PARITY (test_per_field_ranking).
#   [2] equal-top tie: engine emits :needs_review where SourcesRanker deterministically picks one
#       by array order — a behavioural DIVERGENCE to reconcile (test_tie_diverges).
#   [3] the off-product penalty makes a source's rank depend on the PRODUCT's orgs; Priority.rank/3
#       and Survivorship.decide/3 take no product context, so ONE static Priority cannot reproduce
#       both contexts — the single structural GAP (test_context_penalty_is_the_gap).
alias GoldenRecord.{Priority, Survivorship}

defmodule SurvivorshipParitySpikeTest do
  use ExUnit.Case, async: true

  # [1] PARITY — per-field ranking. SourcesRanker: field "name" scores orgA=10, orgB=5 (higher wins).
  # Encode as descending-score tiers (tier 0 = best). Engine must pick orgA.
  test "per-field ranking reproduces a SourcesRanker decision" do
    priority = Priority.new(%{"name" => [["orgA"], ["orgB"]]}, [])

    entries = [
      %{source: "orgA", value: "Foo", order: 1},
      %{source: "orgB", value: "Bar", order: 2}
    ]

    decision = Survivorship.decide("name", entries, priority)
    assert decision.value == "Foo"
    assert decision.winner == "orgA"
    assert decision.status == :resolved
  end

  # [2] DIVERGENCE — equal top tier, differing values. SourcesRanker always returns ONE source
  # (array-order tiebreak); the engine flags it instead. Better, but not byte-identical.
  test "equal-top tie diverges: engine flags needs_review, SourcesRanker would pick one" do
    priority = Priority.new(%{"name" => [["orgA", "orgB"]]}, [])

    entries = [
      %{source: "orgA", value: "Foo", order: 1},
      %{source: "orgB", value: "Bar", order: 2}
    ]

    assert Survivorship.decide("name", entries, priority).status == :needs_review
  end

  # [3] THE GAP — the off-product penalty makes rank product-context-dependent.
  #   source X: non-system, scored 0 by default.
  #   context P1: X is NOT on the product  -> SourcesRanker devalues X to -1 -> Y (default 0) WINS.
  #   context P2: X IS on the product      -> X scores 0 == Y 0            -> TIE.
  # A single Priority can satisfy at most one context.
  test "context penalty is the structural gap: one static Priority can't satisfy both products" do
    entries = [
      %{source: "X", value: "vx", order: 1},
      %{source: "Y", value: "vy", order: 2}
    ]

    # Table tuned for P1 (X off-product => Y must win):
    p1 = Priority.new(%{"name" => [["Y"], ["X"]]}, [])
    assert Survivorship.decide("name", entries, p1).winner == "Y"

    # The SAME table is WRONG for P2, where X and Y should tie (needs_review), not "Y strictly wins":
    assert Survivorship.decide("name", entries, p1).status == :resolved

    # rank is a pure function of (dimension, source) — no product argument exists to flip the verdict.
    # Reproducing P2 demands a DIFFERENT table, i.e. rank must accept the product's org set.
    assert Priority.rank(p1, "name", "X") == 1
    assert Priority.rank(p1, "name", "Y") == 0
  end
end
