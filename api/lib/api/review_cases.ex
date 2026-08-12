defmodule Api.ReviewCases do
  @moduledoc """
  Evidence snapshots for human decisions.

  A case is not permission to act forever. It records the exact members, claims, and event offset
  a steward reviewed. The second approval recomputes that scoped evidence under the writer lock;
  unrelated events may advance the log, but changed evidence makes the case stale.
  """

  def open_from_flag(state, %Events.ConflictFlagged{subject: subject, order: offset}) do
    case evidence(state, subject) do
      {:ok, evidence} -> put_case(state, "case_#{offset}", subject, evidence, offset)
      {:error, _} -> state
    end
  end

  def open_derived(state, subject, offset) do
    case evidence(state, subject) do
      {:ok, evidence} -> put_case(state, "case_#{offset}", subject, evidence, offset)
      {:error, _} -> state
    end
  end

  def apply_opened(state, %Events.ReviewCaseOpened{} = opened) do
    case_map = %{
      id: opened.case_id,
      subject: opened.subject,
      evidence: opened.evidence,
      evidence_digest: opened.evidence_digest,
      evidence_offset: opened.evidence_offset,
      required_approvals: opened.required_approvals,
      endorsements: %{},
      status: :open
    }

    install(state, case_map)
  end

  def apply_endorsed(state, %Events.ReviewCaseEndorsed{} = endorsement) do
    update_case(state, endorsement.case_id, fn review ->
      entry = %{
        principal: endorsement.principal,
        proposal: endorsement.proposal,
        reason: endorsement.reason,
        order: endorsement.order
      }

      %{review | endorsements: Map.put(review.endorsements, endorsement.principal, entry)}
    end)
  end

  def close_subject(state, subject, outcome) do
    case Map.get(state.active_case_by_subject, subject) do
      nil ->
        state

      case_id ->
        state
        |> update_case(case_id, &%{&1 | status: outcome})
        |> Map.update!(:active_case_by_subject, &Map.delete(&1, subject))
    end
  end

  def fetch_open(state, case_id, expected_offset) do
    with %{status: :open} = review <- Map.get(state.review_cases, case_id),
         true <- review.evidence_offset == expected_offset,
         {:ok, evidence} <- evidence(state, review.subject),
         digest when digest == review.evidence_digest <- digest(evidence) do
      {:ok, review}
    else
      nil -> {:error, :missing}
      %{status: _} -> {:error, :closed}
      false -> {:error, :wrong_offset}
      {:error, reason} -> {:error, reason}
      _digest -> {:error, :stale}
    end
  end

  def opened_event(state, subject, principal, at) do
    with {:ok, evidence} <- evidence(state, subject) do
      offset = state.offset
      case_id = "case_#{offset + 1}"

      {:ok,
       %Events.ReviewCaseOpened{
         case_id: case_id,
         subject: subject,
         evidence: evidence,
         evidence_digest: digest(evidence),
         evidence_offset: offset,
         required_approvals: required_approvals(subject),
         recorded_at: at
       }, principal}
    end
  end

  def evidence(state, {:merge, keys}) do
    keys = keys |> Enum.uniq() |> Enum.sort()
    live = Map.keys(state.ledger.members)
    lanes = Enum.map(keys, &Lanes.lane_of_key/1) |> Enum.uniq()

    cond do
      length(keys) < 2 -> {:error, :invalid_target}
      keys -- live != [] -> {:error, :missing_target}
      length(lanes) != 1 -> {:error, :cross_lane}
      true -> {:ok, identity_evidence(state, :merge, keys, hd(lanes))}
    end
  end

  def evidence(state, {:attr, key, field}) do
    with codes when not is_nil(codes) <- Map.get(state.ledger.members, key),
         {^field, decision} <-
           Enum.find(
             Survivorship.field_decisions(
               codes,
               Enum.filter(Api.State.current_claims(state), &(&1.kind == :attribute)),
               Api.Priority.current()
             ),
             &(elem(&1, 0) == field)
           ),
         true <- decision.status == :needs_review do
      {:ok,
       %{
         kind: :attribute,
         key: key,
         lane: Lanes.lane_of_key(key),
         field: field,
         members: Enum.sort(codes),
         candidates: Enum.sort(decision.candidates)
       }}
    else
      _ -> {:error, :not_contested}
    end
  end

  def evidence(state, {:split, key}) do
    absorbed =
      state.redirects
      |> Enum.filter(fn {_from, into} -> Api.State.follow(state, into) == key end)
      |> Enum.map(&elem(&1, 0))
      |> Enum.sort()

    case {Map.get(state.ledger.members, key), absorbed} do
      {nil, _} ->
        {:error, :missing_target}

      {_members, []} ->
        {:error, :not_a_repair}

      {_members, absorbed} ->
        {:ok, identity_evidence(state, :split, [key | absorbed], Lanes.lane_of_key(key))}
    end
  end

  def evidence(state, {:suppress, from, to}) do
    from = Codes.canonicalize(from)
    to = Codes.canonicalize(to)

    valid_signature = Relations.valid_signature?(:suppress, from, to)

    derived =
      Enum.any?(Api.State.current_claims(state), fn
        %Events.ClaimAsserted{kind: :edge, data: %{from: ^from, relation: :describes, to: ^to}} ->
          true

        _ ->
          false
      end)

    cond do
      not valid_signature -> {:error, :cross_lane}
      not derived -> {:error, :not_derived}
      true -> {:ok, %{kind: :suppress, from: from, to: to, relation: :suppress}}
    end
  end

  def evidence(_state, _subject), do: {:error, :unsupported_case}

  def digest(evidence),
    do:
      :crypto.hash(:sha256, :erlang.term_to_binary(evidence, [:deterministic]))
      |> Base.encode16(case: :lower)

  defp identity_evidence(state, kind, keys, lane) do
    claims = Api.State.current_claims(state)

    evidence = %{
      kind: kind,
      keys: Enum.sort(keys),
      lane: lane,
      claims:
        claims
        |> Enum.filter(&(&1.kind == :identity))
        |> Enum.filter(fn claim ->
          Enum.any?(keys, fn key ->
            members = Map.get(state.ledger.members, key, MapSet.new())
            Enum.any?(claim.data.codes, &MapSet.member?(members, &1))
          end)
        end)
        |> Enum.map(fn claim ->
          %{
            source: claim.source,
            ref: claim.data.ref,
            revision: claim.record_revision,
            codes: Enum.sort(claim.data.codes),
            order: claim.order
          }
        end)
        |> Enum.sort_by(&{&1.source, &1.ref, &1.order})
    }

    if kind == :merge do
      evidence
    else
      Map.put(
        evidence,
        :members,
        keys
        |> Enum.map(&{&1, state.ledger.members |> Map.get(&1, MapSet.new()) |> Enum.sort()})
        |> Enum.sort()
      )
    end
  end

  defp put_case(state, case_id, subject, evidence, evidence_offset) do
    digest = digest(evidence)

    case Map.get(state.active_case_by_subject, subject) do
      existing_id when not is_nil(existing_id) ->
        existing = Map.fetch!(state.review_cases, existing_id)

        if existing.evidence_digest == digest do
          state
        else
          state
          |> update_case(existing_id, &%{&1 | status: :superseded})
          |> install(case_map(case_id, subject, evidence, digest, evidence_offset))
        end

      nil ->
        prior =
          state.review_cases
          |> Map.values()
          |> Enum.filter(&(&1.subject == subject))
          |> Enum.max_by(& &1.evidence_offset, fn -> nil end)

        if prior && prior.evidence_digest == digest && prior.status != :superseded,
          do: state,
          else: install(state, case_map(case_id, subject, evidence, digest, evidence_offset))
    end
  end

  defp case_map(case_id, subject, evidence, digest, offset),
    do: %{
      id: case_id,
      subject: subject,
      evidence: evidence,
      evidence_digest: digest,
      evidence_offset: offset,
      required_approvals: required_approvals(subject),
      endorsements: %{},
      status: :open
    }

  defp required_approvals({:attr, _, _}), do: 1
  defp required_approvals(_), do: 2

  defp install(state, review) do
    %{
      state
      | review_cases: Map.put(state.review_cases, review.id, review),
        active_case_by_subject: Map.put(state.active_case_by_subject, review.subject, review.id)
    }
  end

  defp update_case(state, case_id, fun) do
    case Map.fetch(state.review_cases, case_id) do
      {:ok, review} -> %{state | review_cases: Map.put(state.review_cases, case_id, fun.(review))}
      :error -> state
    end
  end
end
