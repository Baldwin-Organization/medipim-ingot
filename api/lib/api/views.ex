defmodule Api.Views do
  @moduledoc "JSON-shaped views over engine structures — serialization only, no decisions."

  def code({scheme, value}), do: "#{scheme}:#{value}"

  def variant(v) do
    %{
      key: v.key,
      codes: v.codes |> Enum.sort() |> Enum.map(&code/1),
      attributes: Enum.map(v.attributes, &attribute/1),
      media:
        Enum.map(v.media, &%{asset: asset(&1.asset), source: to_string(&1.source), uri: &1.uri})
    }
  end

  defp asset({_, _} = code), do: code(code)
  defp asset(key) when is_binary(key), do: key

  defp attribute({field, decision}) do
    %{
      field: to_string(field),
      value: decision.value,
      winner: decision.winner && to_string(decision.winner),
      status: decision.status,
      candidates:
        Enum.map(decision.candidates, fn {s, v} -> %{source: to_string(s), value: v} end)
    }
  end

  # ── the change feed ─────────────────────────────────────────────────────────
  def feed_event(%Events.ClaimAsserted{} = c) do
    %{
      offset: c.order,
      type: "claim",
      kind: c.kind,
      source: to_string(c.source),
      date: c.recorded_at
    }
  end

  def feed_event(%Events.SourceRecordRevised{} = e),
    do: %{
      offset: e.order,
      type: "source_record_#{e.operation}",
      source: e.source,
      ref: e.ref,
      revision: e.revision,
      status: if(e.active, do: "active", else: "withdrawn"),
      date: e.recorded_at
    }

  def feed_event(%Events.SourceRecordKeyBound{} = e),
    do: %{
      offset: e.order,
      type: "source_record_key_bound",
      source: e.source,
      ref: e.ref,
      lane: e.lane,
      key: e.key,
      date: e.recorded_at
    }

  def feed_event(%Events.ReviewCaseOpened{} = e),
    do: %{
      offset: e.order,
      type: "review_case_opened",
      case_id: e.case_id,
      subject: subject(e.subject),
      evidence_offset: e.evidence_offset,
      date: e.recorded_at
    }

  def feed_event(%Events.ReviewCaseEndorsed{} = e),
    do: %{
      offset: e.order,
      type: "review_case_endorsed",
      case_id: e.case_id,
      principal: e.principal,
      evidence_offset: e.evidence_offset,
      reason: e.reason,
      date: e.recorded_at
    }

  def feed_event(%Events.IdentityMinted{} = e),
    do: %{offset: e.order, type: "minted", key: e.key, codes: codes(e.codes), date: e.recorded_at}

  def feed_event(%Events.IdentityMembersChanged{} = e),
    do: %{
      offset: e.order,
      type: "members_changed",
      key: e.key,
      codes: codes(e.codes),
      date: e.recorded_at
    }

  def feed_event(%Events.IdentitiesMerged{} = e),
    do: %{offset: e.order, type: "merged", from: e.from, into: e.into, date: e.recorded_at}

  def feed_event(%Events.IdentitySplit{} = e),
    do: %{
      offset: e.order,
      type: "split",
      key: e.key,
      into: Enum.map(e.into, &elem(&1, 0)),
      date: e.recorded_at
    }

  def feed_event(%Events.IdentityRetracted{} = e),
    do: %{
      offset: e.order,
      type: "retracted",
      key: e.key,
      codes: codes(e.codes),
      date: e.recorded_at
    }

  def feed_event(%Events.LegacyIdAssigned{} = e),
    do: %{
      offset: e.order,
      type: "legacy_id_assigned",
      key: e.key,
      legacy_id: e.legacy_id,
      date: e.recorded_at
    }

  def feed_event(%Events.ConflictFlagged{subject: {:merge, keys}} = e),
    do: %{offset: e.order, type: "merge_proposal", keys: keys, date: e.recorded_at}

  def feed_event(%Events.ConflictFlagged{} = e),
    do: %{offset: e.order, type: "flag", subject: subject(e.subject), date: e.recorded_at}

  def feed_event(%Events.MergeProposed{} = e),
    do: %{
      offset: e.order,
      type: "merge_endorsed",
      keys: e.keys,
      by: to_string(e.by),
      reason: e.reason,
      date: e.recorded_at
    }

  def feed_event(%Events.ConflictResolved{} = e),
    do: %{
      offset: e.order,
      type: "decision",
      subject: subject(e.subject),
      decision: decision(e.decision),
      by: to_string(e.by),
      reason: e.reason,
      date: e.recorded_at
    }

  def subject({:attr, key, field}), do: "attr:#{key}/#{field}"
  def subject({:merge, keys}), do: "merge:#{Enum.join(keys, "+")}"
  def subject({:split, key}), do: "split:#{key}"
  def subject({:collision, key}), do: "collision:#{key}"
  def subject({:code, code}), do: "code:#{code(code)}"
  def subject(other), do: inspect(other)

  def decision({:pick, value}), do: "pick #{value}"
  def decision({:product, product}), do: "product #{product}"
  def decision(other), do: to_string(other)

  defp codes(%MapSet{} = set), do: set |> Enum.sort() |> Enum.map(&code/1)
end
