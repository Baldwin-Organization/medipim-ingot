# test/survivorship_policy_test.exs — gr-6y2: Survivorship is policy-driven (rankings always on).
#
# Proves the engine seam that keeps medipim-specific scoring OUT of the generic core:
#   * %Priority{}  -> tier ranking, unchanged (back-compat).
#   * injected fn  -> context-aware rank (medipim's off-product penalty lives HERE, not in Priority).
# Attribute rankings are ALWAYS applied — there is no "off" for attribute survivorship (the toggle
# we want lives on identity-conflict guarding instead; see test/identity_conflict_explained_test.exs).
defmodule SurvivorshipPolicyTest do
  use ExUnit.Case, async: true

  defp e(source, value, order), do: %{source: source, value: value, order: order}

  test "back-compat: a %Priority{} still ranks by tier" do
    priority = Priority.new(%{"name" => [["orgA"], ["orgB"]]}, [])
    d = Survivorship.decide("name", [e("orgA", "Foo", 1), e("orgB", "Bar", 2)], priority)
    assert d.winner == "orgA"
    assert d.value == "Foo"
    assert d.status == :resolved
  end

  test "injected rank fn expresses medipim's off-product penalty (context-aware)" do
    scores = %{"name" => %{"A" => 10, "B" => 5}}

    # rank fn closes over the product's scoring org-set; an off-product source is devalued to -1.
    rank = fn scoring_orgs ->
      fn dim, src ->
        base = get_in(scores, [dim, src]) || 0
        score = if MapSet.member?(scoring_orgs, src), do: base, else: -1
        -score
      end
    end

    entries = [e("B", "keep", 1), e("X", "drop", 2)]

    # Product P1: X is NOT on the product -> penalised below default-0/on-product sources -> B wins.
    p1 = rank.(MapSet.new(["A", "B"]))
    assert Survivorship.decide("name", entries, p1).winner == "B"

    # Product P2: X IS on the product -> scores default 0, B (off-product here) is penalised -> X wins.
    # Same claims, different context, different winner — exactly what one static Priority could not do.
    p2 = rank.(MapSet.new(["X"]))
    assert Survivorship.decide("name", entries, p2).winner == "X"
  end

  test "an equal-rank disagreement has no made-up winner and is independent of input order" do
    policy = Priority.new(%{}, [])

    entries = [
      e("source-b", "Beta", 2),
      e("source-a", "Alpha", 1),
      e("source-c", "Gamma", 3)
    ]

    expected = %{
      value: nil,
      winner: nil,
      status: :needs_review,
      candidates: [{"source-a", "Alpha"}, {"source-b", "Beta"}, {"source-c", "Gamma"}]
    }

    assert Survivorship.decide("name", entries, policy) == expected
    assert Survivorship.decide("name", Enum.reverse(entries), policy) == expected
  end

  test "equal-rank sources that agree still resolve" do
    policy = Priority.new(%{}, [])
    decision = Survivorship.decide("name", [e("source-b", "Same", 2), e("source-a", "Same", 1)], policy)

    assert decision.value == "Same"
    assert decision.winner == "source-a"
    assert decision.status == :resolved
  end
end
