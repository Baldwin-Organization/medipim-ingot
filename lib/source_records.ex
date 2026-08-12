defmodule SourceRecords do
  @moduledoc """
  Pure lifecycle rules for one upstream record.

  A record is addressed by `{source, ref}` and revised atomically. `replace` supplies the whole
  record, `patch` changes only named facts, `withdraw` contributes nothing, and `reactivate`
  supplies a fresh whole record. Every accepted event stores the resulting complete snapshot,
  so replay never depends on a future version of the patch algorithm.
  """

  alias Events.{ClaimAsserted, SourceRecordRevised}

  @type operation :: :replace | :patch | :withdraw | :reactivate

  @doc """
  Materialize a source-record command.

  Required options: `source`, `ref`, `revision`, `operation`, `recorded_at`.
  Optional: `base_revision`, `valid_from`, `claims`, and `remove_slots`.
  """
  def revise(current, opts) do
    source = Keyword.fetch!(opts, :source)
    ref = Keyword.fetch!(opts, :ref)
    revision = Keyword.fetch!(opts, :revision)
    operation = Keyword.fetch!(opts, :operation)
    recorded_at = Keyword.fetch!(opts, :recorded_at)
    valid_from = Keyword.get(opts, :valid_from, recorded_at)
    valid_to = Keyword.get(opts, :valid_to)
    base_revision = Keyword.get(opts, :base_revision)
    incoming = Keyword.get(opts, :claims, [])
    remove_slots = MapSet.new(Keyword.get(opts, :remove_slots, []))

    claims =
      Enum.map(incoming, fn %ClaimAsserted{} = claim ->
        %{claim | source: source, record_ref: ref, record_revision: revision}
      end)

    fingerprint =
      fingerprint({
        source,
        ref,
        revision,
        base_revision,
        operation,
        Enum.map(claims, &claim_identity/1),
        remove_slots,
        valid_from,
        valid_to
      })

    with :ok <- validate_address(source, ref, revision),
         :ok <- validate_interval(valid_from, valid_to) do
      case revision_gate(current, revision, base_revision, fingerprint) do
        :replay ->
          {:replay, current}

        :ok ->
          with {:ok, active, snapshot} <- materialize(current, operation, claims, remove_slots),
               :ok <- validate_snapshot(active, snapshot) do
            {:ok,
             %SourceRecordRevised{
               source: source,
               ref: ref,
               revision: revision,
               base_revision: base_revision,
               operation: operation,
               active: active,
               claims: snapshot,
               fingerprint: fingerprint,
               valid_from: valid_from,
               valid_to: valid_to,
               recorded_at: recorded_at
             }}
          end

        error ->
          error
      end
    end
  end

  @doc "Facts contributed by the current record; withdrawn records contribute none."
  def claims(%SourceRecordRevised{active: true, claims: claims}), do: claims
  def claims(%SourceRecordRevised{}), do: []

  @doc false
  def claim_map(claims), do: Map.new(claims, &{Substrate.local_slot(&1), &1})

  defp materialize(nil, :replace, claims, _remove), do: {:ok, true, complete(claims)}

  defp materialize(nil, operation, _claims, _remove),
    do: {:error, {409, "first revision must use replace, got #{operation}"}}

  defp materialize(%SourceRecordRevised{active: false}, :reactivate, claims, _remove),
    do: {:ok, true, complete(claims)}

  defp materialize(%SourceRecordRevised{active: false}, operation, _claims, _remove),
    do: {:error, {409, "withdrawn record must use reactivate, got #{operation}"}}

  defp materialize(%SourceRecordRevised{active: true}, :replace, claims, _remove),
    do: {:ok, true, complete(claims)}

  defp materialize(%SourceRecordRevised{active: true, claims: existing}, :patch, claims, remove) do
    patched =
      existing
      |> claim_map()
      |> Map.drop(MapSet.to_list(remove))
      |> Map.merge(claim_map(claims))
      |> Map.values()
      |> complete()

    {:ok, true, patched}
  end

  defp materialize(%SourceRecordRevised{active: true, claims: existing}, :withdraw, claims, remove) do
    if claims == [] and MapSet.size(remove) == 0,
      do: {:ok, false, existing},
      else: {:error, {422, "withdraw does not accept claims or remove selectors"}}
  end

  defp materialize(%SourceRecordRevised{active: true}, :reactivate, _claims, _remove),
    do: {:error, {409, "active record cannot be reactivated"}}

  defp validate_snapshot(false, _claims), do: :ok

  defp validate_snapshot(true, claims) do
    identities = Enum.filter(claims, &(&1.kind == :identity))

    cond do
      length(identities) != 1 ->
        {:error, {422, "an active source record must contain exactly one identity claim"}}

      hd(identities).data.codes == [] ->
        {:error, {422, "an active source record identity must contain at least one code"}}

      true ->
        :ok
    end
  end

  defp revision_gate(nil, _revision, nil, _fingerprint), do: :ok

  defp revision_gate(nil, _revision, _base, _fingerprint),
    do: {:error, {412, "a new record cannot name a base revision"}}

  defp revision_gate(
         %SourceRecordRevised{revision: revision, fingerprint: fingerprint},
         revision,
         _base,
         fingerprint
       ),
       do: :replay

  defp revision_gate(%SourceRecordRevised{revision: revision}, revision, _base, _fingerprint),
    do: {:error, {409, "revision already exists with different content"}}

  defp revision_gate(%SourceRecordRevised{revision: current}, _revision, current, _fingerprint), do: :ok

  defp revision_gate(%SourceRecordRevised{revision: current}, _revision, base, _fingerprint),
    do: {:error, {412, "base revision #{inspect(base)} does not match current revision #{inspect(current)}"}}

  defp validate_address(source, ref, revision) do
    if Enum.all?([source, ref, revision], &(is_binary(&1) and String.trim(&1) != "")),
      do: :ok,
      else: {:error, {422, "source, ref, and revision must be non-empty strings"}}
  end

  defp validate_interval(%Date{}, nil), do: :ok

  defp validate_interval(%Date{} = valid_from, %Date{} = valid_to) do
    if Date.before?(valid_from, valid_to),
      do: :ok,
      else: {:error, {422, "valid_to must be later than valid_from"}}
  end

  defp validate_interval(_valid_from, _valid_to),
    do: {:error, {422, "valid_from and valid_to must be ISO dates"}}

  defp complete(claims),
    do: claims |> claim_map() |> Enum.sort_by(fn {slot, _} -> slot end) |> Enum.map(&elem(&1, 1))

  defp claim_identity(claim),
    do: {Substrate.local_slot(claim), claim.kind, claim.data, claim.valid_from}

  defp fingerprint(term),
    do: :crypto.hash(:sha256, :erlang.term_to_binary(term, [:deterministic])) |> Base.encode16()
end
