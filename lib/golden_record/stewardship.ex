defmodule GoldenRecord.Stewardship do
  alias GoldenRecord.{Events, Codes, Substrate, Survivorship, IdentityLedger}

  @doc "Flag every attribute priority cannot settle (a tie at the top tier)."
  def detect(members, live_claims, priority, at) do
    attrs = Enum.filter(live_claims, &(&1.kind == :attribute))

    for {key, codes} <- members,
        {field, decision} <- Survivorship.field_decisions(codes, attrs, priority),
        decision.status == :needs_review do
      %Events.ConflictFlagged{subject: {:attr, key, field}, candidates: decision.candidates, recorded_at: at}
    end
  end

  @doc """
  Flag a SOURCE WITHDRAWAL: a source retracted its listing (codes: []) but the key survives
  under other sources. The steward needs visibility — the product lost evidence.
  """
  def detect_withdrawals(old_live, new_live, members, at) do
    # code -> [key] built once; a held conflict can put one code in several keys' sets.
    keys_by_code =
      for {key, codes} <- members, code <- codes, reduce: %{} do
        acc -> Map.update(acc, code, [key], &[key | &1])
      end

    old_sources = sources_per_key(old_live, keys_by_code)
    new_sources = sources_per_key(new_live, keys_by_code)

    for {key, _codes} <- members,
        old = Map.get(old_sources, key, MapSet.new()),
        new = Map.get(new_sources, key, MapSet.new()),
        lost = MapSet.difference(old, new),
        MapSet.size(lost) > 0 do
      %Events.ConflictFlagged{
        subject: {:source_withdrew, key},
        candidates: Enum.map(lost, &%{source: &1}),
        recorded_at: at
      }
    end
  end

  defp sources_per_key(live_claims, keys_by_code) do
    for claim <- live_claims,
        claim.kind == :identity,
        claim.data.codes != [],
        key <- claim.data.codes |> Enum.flat_map(&Map.get(keys_by_code, &1, [])) |> Enum.uniq(),
        reduce: %{} do
      acc -> Map.update(acc, key, MapSet.new([claim.source]), &MapSet.put(&1, claim.source))
    end
  end

  @doc "Flag a CODE COLLISION: one variant whose grouping claims point at >1 distinct product."
  def detect_collisions(members, live_claims, at) do
    groups = Enum.filter(live_claims, &(&1.kind == :grouping))

    for {key, codes} <- members,
        prods = products_of(codes, groups),
        length(Enum.uniq(Enum.map(prods, & &1.product))) > 1 do
      %Events.ConflictFlagged{subject: {:collision, key}, candidates: prods, recorded_at: at}
    end
  end

  defp products_of(codes, groups) do
    groups
    |> Enum.filter(&MapSet.member?(codes, &1.data.code))
    |> Enum.map(&%{source: &1.source, product: &1.data.product})
  end

  def resolve_attribute(key, field, value, by, at, reason \\ nil),
    do: [
      %Events.ConflictResolved{
        subject: {:attr, key, field},
        decision: {:pick, value},
        by: by,
        reason: reason,
        recorded_at: at
      }
    ]

  def reject_merge(keys, by, at, reason \\ nil),
    do: [
      %Events.ConflictResolved{
        subject: {:merge, Enum.sort(keys)},
        decision: :rejected,
        by: by,
        reason: reason,
        recorded_at: at
      }
    ]

  def mark_shared(scheme_code, by, at),
    do: [%Events.ConflictResolved{subject: {:code, scheme_code}, decision: :shared, by: by, recorded_at: at}]

  @doc "Steward verdict on a code collision: this variant truly belongs to ONE product."
  def resolve_collision(key, product, by, at),
    do: [
      %Events.ConflictResolved{
        subject: {:collision, key},
        decision: {:product, product},
        by: by,
        recorded_at: at
      }
    ]

  @doc """
  Endorse a merge proposal — the four-eyes gate. Merging ESTABLISHED keys needs two distinct
  stewards: the first endorsement records a `MergeProposed`, the second (by a DIFFERENT steward)
  fuses via `approve_merge/5`. The same steward endorsing twice is refused HERE, by the decision
  function — no router or UI gets a say. `pending` is the open proposal (anything with a `:by`,
  e.g. the folded `MergeProposed`) or `nil`.
  """
  def endorse_merge(members, keys, pending, by, at, reason \\ nil)

  def endorse_merge(_members, keys, nil, by, at, reason),
    do: {:proposed, propose_merge(keys, by, at, reason)}

  def endorse_merge(_members, _keys, %{by: proposer}, by, _at, _reason) when proposer == by,
    do: {:error, :four_eyes}

  def endorse_merge(members, keys, %{by: _other}, by, at, reason),
    do: {:ok, approve_merge(members, keys, by, at, reason)}

  @doc "The first of the four eyes: record a steward's endorsement of a merge, fusing nothing."
  def propose_merge(keys, by, at, reason \\ nil),
    do: [%Events.MergeProposed{keys: Enum.sort(keys), by: by, reason: reason, recorded_at: at}]

  @doc "The raw fuse — emits the merge events. The steward surface reaches it via `endorse_merge/6`."
  def approve_merge(members, keys, by, at, reason \\ nil) do
    keys = Enum.sort(keys)
    [survivor | _] = keys
    union = keys |> Enum.map(&Map.get(members, &1, MapSet.new())) |> Enum.reduce(&MapSet.union/2)

    standing_same_evidence =
      for {left_key, index} <- Enum.with_index(keys),
          right_key <- Enum.drop(keys, index + 1),
          {scheme, _} = left <- Map.get(members, left_key, MapSet.new()),
          {^scheme, _} = right <- Map.get(members, right_key, MapSet.new()),
          left != right,
          Codes.national_grade?(scheme),
          uniq: true do
        Substrate.claim(
          :steward,
          :identity_evidence,
          %{relation: :same, left: left, right: right, by: by, reason: reason},
          at,
          at
        )
      end

    standing_same_evidence ++
      [
        %Events.IdentitiesMerged{from: keys, into: survivor, recorded_at: at},
        %Events.IdentityMembersChanged{key: survivor, codes: union, recorded_at: at},
        %Events.ConflictResolved{
          subject: {:merge, keys},
          decision: :approved,
          by: by,
          reason: reason,
          recorded_at: at
        }
      ]
  end

  @doc """
  Suppress one derived description↔product pairing (gr-745) — four-eyes, exactly like merges:
  the first steward endorsement records a proposal, a second DISTINCT steward emits the steward
  suppress edge. The suppression is an ordinary `:edge` claim (source `:steward`, relation
  `:suppress`, description code → product code), so it is retractable, bitemporal, visible in
  history, and re-homes on splits like every other edge. It hides the description on THAT
  product only — the substance tag stays intact. `pending` is the open proposal or `nil`
  (see `pending_suppress/3`).
  """
  def endorse_suppress(from, to, pending, by, at, reason \\ nil)

  def endorse_suppress(from, to, nil, by, at, reason),
    do:
      {:proposed,
       [%Events.MergeProposed{keys: [suppress_subject(from, to)], by: by, reason: reason, recorded_at: at}]}

  def endorse_suppress(_from, _to, %{by: proposer}, by, _at, _reason) when proposer == by,
    do: {:error, :four_eyes}

  def endorse_suppress(from, to, %{by: _other}, by, at, reason) do
    {:ok,
     [
       Substrate.claim(:steward, :edge, %{from: from, relation: :suppress, to: to}, at, at),
       %Events.ConflictResolved{
         subject: suppress_subject(from, to),
         decision: :approved,
         by: by,
         reason: reason,
         recorded_at: at
       }
     ]}
  end

  @doc "The open suppress proposal for this description↔product pairing, or nil (decided/none)."
  def pending_suppress(log, from, to) do
    subject = suppress_subject(from, to)

    if Enum.any?(log, &match?(%Events.ConflictResolved{subject: ^subject}, &1)),
      do: nil,
      else: Enum.find(log, &match?(%Events.MergeProposed{keys: [^subject]}, &1))
  end

  defp suppress_subject(from, to), do: {:suppress, Codes.canonicalize(from), Codes.canonicalize(to)}

  @doc """
  Steward-initiated split: carve groups of codes out of `key` into freshly minted keys; whatever
  remains stays with the original key. Mirrors `approve_merge/4`, but takes the ledger — minting
  the carved-out keys needs its `next` counter. Carve-out codes are canonicalized and clipped to
  the codes the key actually owns. The decision event records WHO split (`IdentitySplit` has no
  `by` field), so the steward survives in the lineage.
  """
  def split(
        %IdentityLedger{members: members, next: next, prefix: prefix},
        key,
        carve_outs,
        by,
        at,
        reason \\ nil
      ) do
    owned = Map.get(members, key, MapSet.new())

    {into, _} =
      Enum.map_reduce(carve_outs, next, fn codes, n ->
        carved = codes |> MapSet.new(&Codes.canonicalize/1) |> MapSet.intersection(owned)
        {{"#{prefix}_#{n}", carved}, n + 1}
      end)

    kept = Enum.reduce(into, owned, fn {_k, codes}, acc -> MapSet.difference(acc, codes) end)

    [
      %Events.IdentitySplit{key: key, kept_codes: kept, into: into, recorded_at: at},
      %Events.ConflictResolved{
        subject: {:split, key},
        decision: :approved,
        by: by,
        reason: reason,
        recorded_at: at
      }
    ]
  end

  @doc "Codes a steward has declared legitimately shared (read from the log)."
  def shared_codes(log) do
    for %Events.ConflictResolved{subject: {:code, c}, decision: :shared} <- log, into: MapSet.new(), do: c
  end

  @doc "Pair each flagged conflict with its verdict (or nil if still open)."
  def queue(log) do
    resolved = for %Events.ConflictResolved{} = e <- log, into: %{}, do: {e.subject, e}
    for %Events.ConflictFlagged{} = f <- log, do: {f, Map.get(resolved, f.subject)}
  end
end
