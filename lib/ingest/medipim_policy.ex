# lib/ingest/medipim_policy.ex — the CONCRETE medipim survivorship scoring policy (gr-7yw).
#
# This is the medipim integration boundary: the generic engine (Survivorship) only consumes an
# injected `(dimension, source) -> rank` function, and everything medipim-specific — per-field
# score maps, org-group (sysId) resolution, the off-product −1 penalty, the BE-only labo-org
# union, in-flight-delta orgs, the legacy array-order tie-break — closes over that function here.
# The generic core stays medipim-free.
#
# Faithfully reproduces `SourcesRanker` (verified against medipim in gr-6y2's read-only audit):
#
#   * each FIELD carries a score map (sysId | orgId) => int; a source's score resolves by its
#     sysId (org group) FIRST, then its orgId, else default 0
#   * PENALTY: a non-system source NOT in the product's scoring org-set is devalued to −1, so it
#     loses to any default-0 on-product source. The scoring set is the product's organizations,
#     ∪ labo orgs for region :be ONLY (`getProductSnapshotCurrentOrganizations`), ∪ orgs
#     introduced by the in-flight delta (a source about to be added still ranks)
#   * highest score wins; equal scores break by legacy source-array order (DECISION, Ward
#     2026-08-13: replicate the array-order pick for byte-parity — :needs_review is NOT the
#     default under this policy)
#
# The `penalty: false` toggle is the flip-frequency measurement lever (gr-6y2 slice 5): fold with
# and without the −1 band and diff the winners — see `penalty_flips/2`.
defmodule MedipimPolicy do
  @moduledoc """
  Builds the injected rank function `GoldenRecords.project/2` (and `Survivorship.decide/3`)
  accept as a policy, from a medipim scoring context:

    * `:field_scores` — `%{field => %{sysId_or_orgId => integer_score}}`
    * `:sys_of` — `%{orgId => sysId}` (org → org-group)
    * `:product_orgs` — org ids on the product snapshot
    * `:labo_orgs` — labo org ids (merged into the scoring set for region `:be` only)
    * `:delta_orgs` — orgs introduced by the in-flight delta (still rank)
    * `:system_sources` — sources never penalized
    * `:source_order` — the legacy SourcesRanker array order (equal-score tie-break)
    * `:region` — `:be` includes labo orgs in the scoring set
    * `:penalty` — the −1 off-product band toggle (default `true`); the measurement lever
  """

  # rank = -score * @offset + tie_index — one integer, totally ordered, lower wins.
  # Encodes {higher score wins, then earlier array position wins} without tuple ranks, because
  # the PHP seam types ranks as int|float. @offset just needs to exceed any source-array length.
  @offset 1_000_000
  @unlisted @offset - 1

  @defaults %{
    region: :be,
    product_orgs: [],
    labo_orgs: [],
    delta_orgs: [],
    system_sources: [],
    field_scores: %{},
    sys_of: %{},
    source_order: [],
    penalty: true
  }

  @doc "The injected 2-arity rank function (lower rank wins) for `context` (see moduledoc)."
  def rank_fn(context) do
    ctx = normalize(context)
    fn dimension, source -> -score(ctx, dimension, source) * @offset + tie_index(ctx, source) end
  end

  @doc """
  The −1 penalty flip report (gr-6y2 slice 5): project `rederivation` with the policy's penalty
  band on and off, and list every `{key, field}` whose decision changed — the fields where the
  off-product devaluation, not the score table, picks the winner. Returns
  `%{flips: [...], decisions: total}` so the frequency is `length(flips) / decisions`.
  """
  def penalty_flips(rederivation, context) do
    on = decisions(GoldenRecords.project(rederivation, rank_fn(context)))

    off =
      decisions(GoldenRecords.project(rederivation, rank_fn(Map.put(normalize(context), :penalty, false))))

    flips =
      for {slot, decision_on} <- Enum.sort(on),
          decision_off = Map.fetch!(off, slot),
          decision_on != decision_off do
        {key, field} = slot
        %{key: key, field: field, with_penalty: decision_on, without_penalty: decision_off}
      end

    %{flips: flips, decisions: map_size(on)}
  end

  defp decisions(%{records: records}) do
    for %{variants: variants} <- records,
        %{key: key, attributes: attributes} <- variants,
        {field, decision} <- attributes,
        into: %{} do
      {{key, field}, %{value: decision.value, winner: decision.winner, status: decision.status}}
    end
  end

  defp normalize(%{scoring_set: _} = ctx), do: ctx

  defp normalize(context) do
    ctx = Map.merge(@defaults, Map.new(context))
    labo = if ctx.region == :be, do: ctx.labo_orgs, else: []

    ctx
    |> Map.put(:scoring_set, MapSet.new(Enum.concat([ctx.product_orgs, labo, ctx.delta_orgs])))
    |> Map.put(:system_set, MapSet.new(ctx.system_sources))
    |> Map.put(:tie_order, ctx.source_order |> Enum.with_index() |> Map.new())
  end

  defp score(ctx, dimension, source) do
    if ctx.penalty and off_product?(ctx, source), do: -1, else: configured(ctx, dimension, source)
  end

  defp off_product?(ctx, source),
    do: not MapSet.member?(ctx.system_set, source) and not MapSet.member?(ctx.scoring_set, source)

  # sysId (org group) resolves BEFORE orgId; a source in neither map scores the default 0.
  defp configured(ctx, dimension, source) do
    scores = Map.get(ctx.field_scores, dimension, %{})

    with :error <- sys_score(scores, Map.get(ctx.sys_of, source)),
         :error <- Map.fetch(scores, source) do
      0
    else
      {:ok, s} -> s
    end
  end

  defp sys_score(_scores, nil), do: :error
  defp sys_score(scores, sys), do: Map.fetch(scores, sys)

  defp tie_index(ctx, source), do: Map.get(ctx.tie_order, source, @unlisted)
end
