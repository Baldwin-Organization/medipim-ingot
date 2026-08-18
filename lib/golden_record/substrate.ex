defmodule GoldenRecord.Substrate do
  alias GoldenRecord.{Events, Codes}

  alias Events.ClaimAsserted

  # Every ingested code is canonicalized here so equivalent representations (EAN-13 vs GTIN-14,
  # UPC vs its EAN-13 form, a GTIN-8 vs its zero-padded width) collapse to one identity.
  #
  # :member_of is the legacy spelling of an :edge (gr-xde): the constructor still accepts it,
  # but the LOG holds the generalized edge — one relationship representation, one traversal.
  def claim(source, :member_of, %{member_code: m, collection: c}, valid_from, recorded_at),
    do: claim(source, :edge, %{from: m, relation: :member_of, to: c}, valid_from, recorded_at)

  def claim(source, kind, data, valid_from, recorded_at),
    do: %ClaimAsserted{
      source: source,
      kind: kind,
      data: normalize(kind, data),
      valid_from: valid_from,
      recorded_at: recorded_at
    }

  defp normalize(:identity, %{codes: codes} = d), do: %{d | codes: Enum.map(codes, &Codes.canonicalize/1)}

  defp normalize(:identity_evidence, %{left: left, right: right} = d),
    do: %{d | left: Codes.canonicalize(left), right: Codes.canonicalize(right)}

  defp normalize(:grouping, %{code: c} = d), do: %{d | code: Codes.canonicalize(c)}
  defp normalize(:attribute, %{code: c} = d), do: %{d | code: Codes.canonicalize(c)}
  defp normalize(:media, %{target: t} = d), do: %{d | target: Codes.canonicalize(t)}

  # Both edge endpoints canonicalize, so an edge addressed by EAN-13 matches a cluster holding
  # the GTIN-14 form. (:member_of claims no longer reach here — claim/5 lowers them to :edge —
  # but a previously persisted log may still carry them, so the clause stays foldable.)
  defp normalize(:edge, %{from: f, to: t} = d),
    do: %{d | from: Codes.canonicalize(f), to: Codes.canonicalize(t)}

  defp normalize(:member_of, %{member_code: m, collection: c} = d),
    do: %{d | member_code: Codes.canonicalize(m), collection: Codes.canonicalize(c)}

  defp normalize(_kind, d), do: d

  # Public (@doc false) so the API's fold-state can maintain the current view INCREMENTALLY —
  # one Map.put per claim instead of re-grouping the whole log per projection.
  @doc false
  def slot(%ClaimAsserted{source: s, record_ref: ref} = claim) when not is_nil(ref),
    do: {s, :record, ref, local_slot(claim)}

  def slot(%ClaimAsserted{source: s, kind: :identity, data: %{ref: r}}), do: {s, :identity, r}

  def slot(%ClaimAsserted{source: s, kind: :identity_evidence, data: %{left: left, right: right}}),
    do: {s, :identity_evidence, left, right}

  def slot(%ClaimAsserted{source: s, kind: :grouping, data: %{code: c}}), do: {s, :grouping, c}
  def slot(%ClaimAsserted{source: s, kind: :attribute, data: %{code: c, field: f}}), do: {s, :attr, c, f}
  def slot(%ClaimAsserted{source: s, kind: :media, data: %{asset: a, target: t}}), do: {s, :media, a, t}

  def slot(%ClaimAsserted{source: s, kind: :edge, data: %{from: f, relation: r, to: t}}),
    do: {s, :edge, f, r, t}

  def slot(%ClaimAsserted{source: s, kind: :member_of, data: %{member_code: m, collection: c}}),
    do: {s, :member_of, m, c}

  @doc false
  def local_slot(%ClaimAsserted{kind: :identity}), do: :identity

  def local_slot(%ClaimAsserted{kind: :identity_evidence, data: %{left: left, right: right}}),
    do: {:identity_evidence, left, right}

  def local_slot(%ClaimAsserted{kind: :grouping, data: %{code: c}}), do: {:grouping, c}
  def local_slot(%ClaimAsserted{kind: :attribute, data: %{code: c, field: f}}), do: {:attr, c, f}
  def local_slot(%ClaimAsserted{kind: :media, data: %{asset: a, target: t}}), do: {:media, a, t}

  def local_slot(%ClaimAsserted{kind: :edge, data: %{from: f, relation: r, to: t}}),
    do: {:edge, f, r, t}

  def local_slot(%ClaimAsserted{kind: :member_of, data: %{member_code: m, collection: c}}),
    do: {:member_of, m, c}

  def current(claims) do
    claims
    |> Enum.group_by(&slot/1)
    |> Enum.map(fn {_slot, cs} -> Enum.max_by(cs, & &1.order) end)
  end
end
