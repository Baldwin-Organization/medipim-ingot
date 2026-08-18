alias GoldenRecord.{Events, Codes, Lanes, IdentityLedger, Stewardship}

defmodule Api.Steward do
  @moduledoc """
  The steward surface's logic: the open queue (merge proposals from the log + attribute ties
  detected fresh, minus everything already decided) and the four decisions, mapped 1:1 onto the
  engine's `Stewardship` functions — recorded with the steward's name and an optional reason,
  applied through the store's writer transaction. A decision against state that has moved on
  answers `409` with what's there now, instead of acting on stale ground.

  Merges of established keys are FOUR-EYES: the first `approve_merge` records an endorsement,
  a second one by a DIFFERENT steward fuses; the same steward twice is refused by the engine
  (`Stewardship.endorse_merge/6`), not by this module or any UI.
  """

  # ── the queue ───────────────────────────────────────────────────────────────
  def queue do
    state = Api.Store.state()
    claims = Api.State.current_claims(state)

    merges =
      for %Events.ConflictFlagged{subject: {:merge, keys}} <- Api.State.open_flags(state) do
        review = active_case(state, {:merge, keys})
        members = Map.new(keys, fn k -> {k, Map.get(state.ledger.members, k, MapSet.new())} end)

        # Codes DIRECTLY shared by two keys' memberships are rare — most bridges are a single
        # LISTING whose codes span the keys. Show those claims, each code tagged with the key it
        # belongs to, so the steward sees exactly WHO connected WHAT (and can judge the claim).
        shared =
          members
          |> Map.values()
          |> Enum.flat_map(&MapSet.to_list/1)
          |> Enum.frequencies()
          |> Enum.filter(fn {_c, n} -> n > 1 end)
          |> Enum.map(fn {c, _} -> Api.Views.code(c) end)
          |> Enum.sort()

        bridges =
          for c <- claims,
              c.kind == :identity,
              codes = MapSet.new(c.data.codes),
              Enum.count(members, fn {_k, m} -> not MapSet.disjoint?(codes, m) end) >= 2 do
            %{
              source: to_string(c.source),
              ref: c.data.ref,
              date: c.recorded_at |> Bitemporal.effective_date() |> Date.to_iso8601(),
              codes:
                for code <- Enum.sort(c.data.codes) do
                  owner =
                    Enum.find_value(members, fn {k, m} -> if MapSet.member?(m, code), do: k end)

                  %{code: Api.Views.code(code), owner: owner}
                end
            }
          end

        bridge_sources = bridges |> Enum.map(& &1.source) |> Enum.uniq()

        %{
          type: "merge",
          case_id: review && review.id,
          evidence_offset: review && review.evidence_offset,
          keys: keys,
          members: Map.new(members, fn {k, _} -> {k, selectable_codes(state, claims, k)} end),
          bridges: bridges,
          bridge_sources: bridge_sources,
          shared: shared,
          proposal: proposal_view(Map.get(state.proposals, Enum.sort(keys)))
        }
      end

    attributes =
      for %Events.ConflictFlagged{subject: {:attr, key, field}, candidates: candidates} <-
            Stewardship.detect(
              state.ledger.members,
              claims,
              Api.Priority.current(),
              Date.utc_today()
            ),
          not MapSet.member?(state.resolved, {:attr, key, field}) do
        review = active_case(state, {:attr, key, field})

        %{
          type: "attribute",
          case_id: review && review.id,
          evidence_offset: review && review.evidence_offset,
          key: key,
          field: to_string(field),
          candidates: Enum.map(candidates, fn {s, v} -> %{source: to_string(s), value: v} end)
        }
      end

    repairs =
      state.redirects
      |> Map.keys()
      |> Enum.group_by(&Api.State.follow(state, &1))
      |> Enum.filter(fn {survivor, _} -> Map.has_key?(state.ledger.members, survivor) end)
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.flat_map(fn {survivor, absorbed} ->
        case active_case(state, {:split, survivor}) do
          nil ->
            []

          review ->
            [
              %{
                case_id: review.id,
                evidence_offset: review.evidence_offset,
                key: survivor,
                merged_from: Enum.sort(absorbed),
                codes: selectable_codes(state, claims, survivor)
              }
            ]
        end
      end)

    %{
      merges: merges,
      attributes: attributes,
      repairs: repairs,
      open: length(merges) + length(attributes)
    }
  end

  # A key's member codes as SELECTABLE entries — each with the sources currently claiming it,
  # so the steward can spot the stranger ("which claim is wrong") instead of typing codes.
  defp selectable_codes(state, claims, key) do
    sources =
      for c <- claims, c.kind == :identity, code <- c.data.codes, reduce: %{} do
        acc ->
          Map.update(acc, code, [to_string(c.source)], &Enum.uniq([to_string(c.source) | &1]))
      end

    state.ledger.members
    |> Map.get(key, MapSet.new())
    |> Enum.sort()
    |> Enum.map(fn code ->
      %{code: Api.Views.code(code), sources: sources |> Map.get(code, []) |> Enum.sort()}
    end)
  end

  defp active_case(state, subject) do
    with case_id when not is_nil(case_id) <- Map.get(state.active_case_by_subject, subject),
         %{status: :open} = review <- Map.get(state.review_cases, case_id) do
      review
    else
      _ -> nil
    end
  end

  # ── decisions ───────────────────────────────────────────────────────────────
  def decide(%{"kind" => "approve_merge", "keys" => keys} = params, principal)
      when is_list(keys) and length(keys) >= 2 do
    Api.Store.append(fn state, _conn ->
      with :ok <- actor_matches(params, principal),
           {:ok, case_id, offset} <- case_reference(params),
           {:ok, review} <- Api.ReviewCases.fetch_open(state, case_id, offset),
           {:ok, sorted} <- exact_subject(review, :merge, keys),
           :ok <- distinct_principal(review, principal) do
        endorsement = endorsement(review, principal, nil, params)

        if map_size(review.endorsements) + 1 < review.required_approvals do
          events = [
            endorsement
            | Stewardship.propose_merge(sorted, principal, DateTime.utc_now(), reason(params))
          ]

          {:ok, events,
           %{
             applied: "propose_merge",
             proposed_by: principal,
             case_id: case_id,
             awaiting: "approval by a second steward"
           }}
        else
          {:ok,
           [
             endorsement
             | Stewardship.approve_merge(
                 state.ledger.members,
                 sorted,
                 principal,
                 DateTime.utc_now(),
                 reason(params)
               )
           ], applied("approve_merge", case_id)}
        end
      else
        {:error, reason} -> decision_error(state, reason)
      end
    end)
    |> respond()
  end

  def decide(%{"kind" => "reject_merge", "keys" => keys} = params, principal)
      when is_list(keys) and length(keys) >= 2 do
    Api.Store.append(fn state, _conn ->
      with :ok <- actor_matches(params, principal),
           {:ok, case_id, offset} <- case_reference(params),
           {:ok, review} <- Api.ReviewCases.fetch_open(state, case_id, offset),
           {:ok, sorted} <- exact_subject(review, :merge, keys) do
        {:ok, Stewardship.reject_merge(sorted, principal, Date.utc_today(), reason(params)),
         applied("reject_merge", case_id)}
      else
        {:error, reason} -> decision_error(state, reason)
      end
    end)
    |> respond()
  end

  def decide(
        %{
          "kind" => "resolve_attribute",
          "key" => key,
          "field" => field,
          "value" => value
        } = params,
        principal
      )
      when is_binary(key) and is_binary(field) do
    Api.Store.append(fn state, _conn ->
      with :ok <- actor_matches(params, principal),
           {:ok, case_id, offset} <- case_reference(params),
           {:ok, review} <- Api.ReviewCases.fetch_open(state, case_id, offset),
           :ok <- exact_attribute(review, key, field),
           true <-
             Enum.any?(review.evidence.candidates, fn {_source, candidate} ->
               candidate == value
             end) do
        {:ok,
         Stewardship.resolve_attribute(
           key,
           field,
           value,
           principal,
           Date.utc_today(),
           reason(params)
         ), applied("resolve_attribute", case_id)}
      else
        false -> {:error, {422, %{error: "value was not one of the reviewed candidates"}}}
        {:error, reason} -> decision_error(state, reason)
      end
    end)
    |> respond()
  end

  def decide(%{"kind" => "split", "key" => key, "codes" => codes} = params, principal)
      when is_binary(key) and is_list(codes) and codes != [] do
    with {:ok, parsed} <- parse_codes(codes) do
      Api.Store.append(fn state, _conn ->
        member = Map.get(state.ledger.members, key)

        with :ok <- actor_matches(params, principal),
             {:ok, case_id, offset} <- case_reference(params),
             {:ok, review} <- Api.ReviewCases.fetch_open(state, case_id, offset),
             :ok <- exact_split(review, key),
             :ok <- valid_split(member, key, parsed),
             :ok <- split_lane(key, parsed),
             :ok <- distinct_principal(review, principal),
             :ok <- same_proposal(review, parsed) do
          endorsement = endorsement(review, principal, Enum.sort(parsed), params)

          if map_size(review.endorsements) + 1 < review.required_approvals do
            {:ok, [endorsement],
             %{
               applied: "propose_split",
               proposed_by: principal,
               case_id: case_id,
               awaiting: "approval by a second steward"
             }}
          else
            {:ok, events, body} = split_events(state, key, parsed, principal, reason(params))
            {:ok, [endorsement | events], Map.put(body, :case_id, case_id)}
          end
        else
          {:error, reason} -> decision_error(state, reason)
        end
      end)
      |> respond()
    else
      {:error, reason} -> {422, %{error: reason}}
    end
  end

  def decide(%{"kind" => "suppress", "from" => raw_from, "to" => raw_to} = params, principal) do
    with {:ok, from} <- CanonicalClaims.parse_code(raw_from),
         {:ok, to} <- CanonicalClaims.parse_code(raw_to) do
      Api.Store.append(fn state, _conn ->
        with :ok <- actor_matches(params, principal) do
          subject = {:suppress, Codes.canonicalize(from), Codes.canonicalize(to)}

          case case_reference(params) do
            {:error, :case_required} ->
              with {:ok, opened, _} <-
                     Api.ReviewCases.opened_event(state, subject, principal, Date.utc_today()) do
                endorsement = %Events.ReviewCaseEndorsed{
                  case_id: opened.case_id,
                  principal: principal,
                  evidence_offset: opened.evidence_offset,
                  proposal: subject,
                  reason: reason(params),
                  recorded_at: Date.utc_today()
                }

                {:ok, [opened, endorsement],
                 %{
                   applied: "propose_suppress",
                   case_id: opened.case_id,
                   evidence_offset: opened.evidence_offset,
                   awaiting: "approval by a second steward"
                 }}
              else
                {:error, reason} -> decision_error(state, reason)
              end

            {:ok, case_id, offset} ->
              with {:ok, review} <- Api.ReviewCases.fetch_open(state, case_id, offset),
                   true <- review.subject == subject,
                   :ok <- distinct_principal(review, principal) do
                endorsement = endorsement(review, principal, subject, params)

                case Stewardship.endorse_suppress(
                       from,
                       to,
                       %{by: first_principal(review)},
                       principal,
                       Date.utc_today(),
                       reason(params)
                     ) do
                  {:ok, events} ->
                    {:ok, [endorsement | events], applied("suppress", case_id)}

                  {:error, reason} ->
                    decision_error(state, reason)
                end
              else
                false -> decision_error(state, :wrong_target)
                {:error, reason} -> decision_error(state, reason)
              end
          end
        else
          {:error, reason} -> decision_error(state, reason)
        end
      end)
      |> respond()
    else
      {:error, reason} -> {422, %{error: reason}}
    end
  end

  def decide(_params, _principal),
    do:
      {422,
       %{
         error:
           "decision must name an open case and be one of: approve_merge/reject_merge, " <>
             "resolve_attribute, split, or suppress"
       }}

  # ── plumbing ────────────────────────────────────────────────────────────────
  defp split_events(state, key, parsed, by, reason) do
    lane = Lanes.lane_of_key(key)
    prefix = Lanes.prefix(lane)

    lane_ledger = %IdentityLedger{
      members: state.ledger.members,
      next: Map.get(state.ledger.next_by_prefix, prefix, state.ledger.next),
      prefix: prefix,
      next_by_prefix: state.ledger.next_by_prefix
    }

    events = Stewardship.split(lane_ledger, key, [parsed], by, Date.utc_today(), reason)
    ledger = Enum.reduce(events, state.ledger, &IdentityLedger.evolve(&2, &1))

    # the carved-out key needs a legacy id of its own — continuity, immediately
    assignments =
      LegacyIds.decide(
        ledger.members,
        Api.State.current_claims(state),
        state.assigned,
        Date.utc_today()
      )

    {:ok, events ++ assignments, applied("split")}
  end

  defp applied(kind), do: %{applied: kind}
  defp applied(kind, case_id), do: %{applied: kind, case_id: case_id}

  defp actor_matches(%{"by" => claimed}, principal) when claimed != principal,
    do: {:error, :actor_spoofing}

  defp actor_matches(_params, _principal), do: :ok

  defp case_reference(%{"case_id" => case_id, "evidence_offset" => offset})
       when is_binary(case_id) and is_integer(offset),
       do: {:ok, case_id, offset}

  defp case_reference(_params), do: {:error, :case_required}

  defp exact_subject(%{subject: {:merge, expected}}, :merge, keys) do
    sorted = keys |> Enum.uniq() |> Enum.sort()

    cond do
      length(sorted) != length(keys) -> {:error, :duplicate_keys}
      sorted != expected -> {:error, :wrong_target}
      true -> {:ok, sorted}
    end
  end

  defp exact_attribute(%{subject: {:attr, key, field}}, key, field), do: :ok
  defp exact_attribute(_review, _key, _field), do: {:error, :wrong_target}

  defp exact_split(%{subject: {:split, key}}, key), do: :ok
  defp exact_split(_review, _key), do: {:error, :wrong_target}

  defp valid_split(nil, _key, _parsed), do: {:error, :missing_target}

  defp valid_split(member, key, parsed) do
    selected = MapSet.new(parsed)

    cond do
      MapSet.subset?(member, selected) -> {:error, {:empty_key, key}}
      MapSet.disjoint?(member, selected) -> {:error, :unowned_codes}
      true -> :ok
    end
  end

  defp split_lane(key, parsed) do
    lane = Lanes.lane_of_key(key)

    lanes =
      parsed
      |> Enum.map(fn {scheme, _} -> Lanes.lane_of_scheme(scheme) end)
      |> Enum.reject(&is_nil/1)

    if Enum.all?(lanes, &(&1 == lane)), do: :ok, else: {:error, :cross_lane}
  end

  defp distinct_principal(review, principal) do
    if Map.has_key?(review.endorsements, principal),
      do: {:error, :four_eyes},
      else: :ok
  end

  defp same_proposal(%{endorsements: endorsements}, _parsed) when map_size(endorsements) == 0,
    do: :ok

  defp same_proposal(review, parsed) do
    expected = review.endorsements |> Map.values() |> hd() |> Map.fetch!(:proposal)
    if expected == Enum.sort(parsed), do: :ok, else: {:error, :wrong_target}
  end

  defp endorsement(review, principal, proposal, params),
    do: %Events.ReviewCaseEndorsed{
      case_id: review.id,
      principal: principal,
      evidence_offset: review.evidence_offset,
      proposal: proposal,
      reason: reason(params),
      recorded_at: Date.utc_today()
    }

  defp first_principal(review), do: review.endorsements |> Map.keys() |> hd()

  defp decision_error(state, reason) do
    case reason do
      :actor_spoofing ->
        {:error, {403, %{error: "request actor does not match authenticated principal"}}}

      :four_eyes ->
        {:error, {422, %{error: "four-eyes requires a different authenticated principal"}}}

      {:empty_key, key} ->
        {:error, {422, %{error: "selecting every code would leave #{key} empty"}}}

      :unowned_codes ->
        {:error, {422, %{error: "split must select at least one code owned by the key"}}}

      :cross_lane ->
        {:error, {422, %{error: "decision crosses incompatible entity lanes"}}}

      :duplicate_keys ->
        {:error, {422, %{error: "merge keys must be unique"}}}

      :case_required ->
        {:error, {422, %{error: "case_id and evidence_offset are required"}}}

      :wrong_target ->
        {:error, {409, %{error: "decision target does not match the reviewed case"}}}

      :stale ->
        stale(state, "review evidence changed; reload the queue")

      :closed ->
        stale(state, "review case is already closed")

      :missing ->
        stale(state, "review case does not exist")

      :wrong_offset ->
        stale(state, "review evidence offset does not match")

      :missing_target ->
        stale(state, "review target is no longer live")

      :not_a_repair ->
        {:error, {422, %{error: "split is only allowed for an open merge repair case"}}}

      :not_derived ->
        {:error,
         {422, %{error: "suppress target is not a currently derived description pairing"}}}

      :invalid_target ->
        {:error, {422, %{error: "invalid review target"}}}

      other ->
        {:error, {422, %{error: "decision rejected: #{inspect(other)}"}}}
    end
  end

  # every decision may carry a free-text justification; blank means none
  defp reason(params) do
    case params["reason"] do
      r when is_binary(r) -> with("" <- String.trim(r), do: nil)
      _ -> nil
    end
  end

  defp proposal_view(nil), do: nil

  defp proposal_view(%Events.MergeProposed{by: by, reason: reason, recorded_at: at}),
    do: %{by: by, reason: reason, at: at}

  defp stale(state, message),
    do:
      {:error,
       {409, %{error: message, live_keys: state.ledger.members |> Map.keys() |> Enum.sort()}}}

  defp respond({:ok, body}), do: {200, body}
  defp respond({:error, {status, body}}), do: {status, body}

  defp parse_codes(codes) do
    codes
    |> Enum.reduce_while({:ok, []}, fn raw, {:ok, acc} ->
      case CanonicalClaims.parse_code(raw) do
        {:ok, code} -> {:cont, {:ok, [code | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      error -> error
    end
  end
end
