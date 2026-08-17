#!/usr/bin/env elixir
#
# Fixture generator (one-off ORACLE, not the runtime ingest) — GENERAL over markets.
#
# Reads a real medipim `products_deltas` history dump for ONE legacy entity
# (`<source>_<entity>.raw.jsonl`, a faithful dump) and emits the decoded-but-unresolved
# `HistoryEnvelope` (`<source>_<entity>.json`) per contract C.
#
# This script applies medipim's decode rules (documented in docs/HISTORY_ENVELOPE.md,
# reverse-engineered from medipimv2's ProductDeltaApplier / Event / GtinCodeHelper /
# ProductMetaFieldBuilder). It is NOT the production decoder: the real system-of-record
# ingest consumes envelopes emitted by medipim's own PHP endpoint (bead gr-867), which
# reuses medipim's battle-tested code. This generator exists only to bootstrap a committed
# fixture from a one-time dump — and its output is precisely the contract that endpoint must
# reproduce.
#
# Run it via `mix run` (NOT bare `elixir`) so lib/ is compiled and CodeRegistry — the single
# source of medipim identity-field knowledge (gr-6k4) — is loadable:
#
#     # decode the Belgian PoC fixture (the reproducible regression guard):
#     mix run test/ingest/fixtures/gen.exs medipim-be 422156
#     # …or equivalently, the thin wrapper:
#     mix run test/ingest/fixtures/gen_422156.exs
#
#     # decode the French fixture:
#     mix run test/ingest/fixtures/gen.exs medipim-fr 347025
#
# Signature — positional argv, with optional explicit paths:
#     mix run test/ingest/fixtures/gen.exs <source_system> <entity_id> [<raw_path> [<out_path>]]
# When the paths are omitted they default to `<this dir>/<source>_<entity>.raw.jsonl` and
# `…/<source>_<entity>.json` (e.g. medipim-be 422156 -> medipim_be_422156.{raw.jsonl,json}).
#
# Decode rules applied here (validated against the real 422156 + 347025 data):
#   - opcode 1=set 2=add 3=remove 4=delete; the string opcode "update_sources" is dropped
#     (a survivorship recompute, not a data change — this engine owns resolution).
#   - key grammar field[:locale][:organizationId]: a trailing all-digit segment is the source
#     (organization id); a 2-letter alpha segment is the locale.
#   - opcode 4 (delete) carries the source in the VALUE, not the key
#     (e.g. ["4","eanGtin13",1034] = drop org 1034's eanGtin13 entry).
#   - some values are stored with a "{field}_" prefix (eanGtin13_/eanGtin14_, and any other
#     field medipim prefixes the same way); the prefix is stripped for ANY field that carries it.
#   - meta fields (updatedAt/updatedBy/createdAt/createdBy/legacyId) are dropped; a delta that
#     reduces to nothing but meta is a touch-only delta (dropped_meta_count++).
#   - last_touched_at = max updatedAt over ALL deltas, including dropped ones.
#   - NO survivorship, NO folding, NO clustering: every source's events are kept, flat and
#     time-ordered. legacy_entity rides along as metadata only.
#   - identity classification is NOT hardcoded here — it is driven by CodeRegistry.identity_fields/0
#     (the medipim field-name set classified :identity), so adding a market is a registry change.

defmodule Gen do
  @here Path.dirname(__ENV__.file)

  @schema_version "1"

  @op %{"1" => "set", "2" => "add", "3" => "remove", "4" => "delete"}
  # identity field-set comes from the registry at runtime (see classify/0). These three are NOT
  # codes and stay decoder-local: media collections, structural edges, and dropped meta fields.
  @media ~w(media descriptions leaflets)
  @edge ~w(publicCategories brands labos internationalBrands medipimCategories organizations)
  @meta_drop ~w(updatedAt updatedBy createdAt createdBy legacyId)

  @doc """
  Decode one entity's raw delta dump into a contract-C envelope.

    * `source_system` — e.g. "medipim-be" / "medipim-fr".
    * `entity_id`     — the legacy medipim entity (productId).
    * `raw_path`      — the `.raw.jsonl` dump (defaults to `<dir>/<source>_<entity>.raw.jsonl`).
    * `out_path`      — the decoded `.json` envelope (defaults to `<dir>/<source>_<entity>.json`).
  """
  def run(source_system, entity_id, raw_path \\ nil, out_path \\ nil) do
    slug = String.replace(source_system, "-", "_") <> "_" <> Integer.to_string(entity_id)
    raw = raw_path || Path.join(@here, slug <> ".raw.jsonl")
    out = out_path || Path.join(@here, slug <> ".json")
    identity = classify()

    {rev_events, dropped, last_touched} =
      raw
      |> File.stream!()
      |> Enum.reduce({[], 0, 0}, &process_line(&1, &2, identity))

    events = Enum.reverse(rev_events)

    envelope = [
      {"schema_version", @schema_version},
      {"source_system", source_system},
      {"legacy_entity", entity_id},
      {"last_touched_at", last_touched},
      {"dropped_meta_count", dropped},
      {"events", events}
    ]

    File.write!(out, enc({:obj, envelope}, 0) <> "\n")
    summarize(events, dropped, last_touched, out)
  end

  # The medipim field names classified :identity — the single source of truth (gr-6k4). Run via
  # `mix run` so lib/ is compiled and CodeRegistry is loaded; bare `elixir` would not have it.
  defp classify do
    unless Code.ensure_loaded?(CodeRegistry) do
      raise "CodeRegistry not loaded — run this oracle via `mix run test/ingest/fixtures/gen.exs ...` (not bare `elixir`)"
    end

    CodeRegistry.identity_fields()
  end

  defp process_line(line, acc, identity) do
    case String.trim(line) do
      "" -> acc
      json -> process_delta(JSON.decode!(json), acc, identity)
    end
  end

  defp process_delta(delta, {events_acc, dropped, last_touched}, identity) do
    recorded_at = delta["created_at"]
    by = delta["created_by"]
    tag = delta["tag"]

    {kept_rev, last_touched} =
      Enum.reduce(delta["events"], {[], last_touched}, fn triple, {kept, lt} ->
        opcode = Enum.at(triple, 0)
        key = Enum.at(triple, 1)
        value = Enum.at(triple, 2)
        field = key && key |> String.split(":") |> hd()

        cond do
          opcode == "update_sources" ->
            {kept, lt}

          field == "updatedAt" ->
            {kept, if(is_integer(value), do: max(lt, value), else: lt)}

          field in @meta_drop ->
            {kept, lt}

          true ->
            ev = decode(field, key, to_string(opcode), value, recorded_at, by, tag, identity)
            {[ev | kept], lt}
        end
      end)

    last_touched = max(last_touched, recorded_at)

    case kept_rev do
      [] -> {events_acc, dropped + 1, last_touched}
      _ -> {Enum.reduce(Enum.reverse(kept_rev), events_acc, &[&1 | &2]), dropped, last_touched}
    end
  end

  # Build one decoded event as an ordered object: recorded_at, by, tag, then the payload.
  defp decode(field, key, opcode, value, recorded_at, by, tag, identity) do
    op = Map.get(@op, opcode, opcode)
    {locale, source} = parse_key(key)
    # opcode 4 (delete): the source lives in the value, and there is no payload value.
    {source, value} = if op == "delete", do: {source_str(value) || source, nil}, else: {source, value}

    head =
      [{"recorded_at", recorded_at}] ++
        if(by != nil, do: [{"by", by}], else: []) ++
        if(tag != nil, do: [{"tag", tag}], else: [])

    {:obj, head ++ payload(field, op, locale, source, value, identity)}
  end

  defp payload(field, op, locale, source, value, identity) do
    kind = kind_of(field, identity)

    base =
      [{"op", op}, {"kind", kind}] ++
        if(source != nil, do: [{"source", source}], else: [])

    base ++ kind_payload(kind, field, op, locale, value)
  end

  defp kind_payload("identity", field, op, _locale, value) do
    [{"scheme", field}] ++
      cond do
        op == "delete" -> []
        value == nil -> [{"code", nil}]
        true -> [{"code", strip_field_prefix(field, to_string(value))}]
      end
  end

  defp kind_payload("attribute", field, op, locale, value) do
    [{"field", field}] ++
      if(locale != nil, do: [{"locale", locale}], else: []) ++
      if(op != "delete", do: [{"value", value}], else: [])
  end

  defp kind_payload("edge", field, op, _locale, value) do
    [{"collection", field}] ++ if(op != "delete", do: [{"value", value}], else: [])
  end

  defp kind_payload("media", field, op, _locale, value) do
    [{"collection", field}] ++ if(op != "delete", do: [{"asset", value}], else: [])
  end

  defp kind_of(field, identity) do
    cond do
      MapSet.member?(identity, field) -> "identity"
      field in @media -> "media"
      field in @edge -> "edge"
      true -> "attribute"
    end
  end

  # Some medipim values carry a redundant "{field}_" prefix (eanGtin13_…, eanGtin14_…, …). Strip a
  # leading "{field}_" for ANY field whose value carries it — generic, not GTIN-only.
  defp strip_field_prefix(field, code) do
    prefix = field <> "_"

    if String.starts_with?(code, prefix),
      do: String.replace_prefix(code, prefix, ""),
      else: code
  end

  # segments after the field: an all-digit one is the source, an alpha one is the locale.
  defp parse_key(key) do
    key
    |> String.split(":")
    |> tl()
    |> Enum.reduce({nil, nil}, fn seg, {locale, source} ->
      cond do
        seg =~ ~r/^\d+$/ -> {locale, seg}
        seg =~ ~r/^[A-Za-z]+$/ -> {seg, source}
        true -> {locale, source}
      end
    end)
  end

  defp source_str(nil), do: nil
  defp source_str(v), do: to_string(v)

  # ---- tiny ordered pretty-printer: structure here, leaf encoding via built-in JSON ----
  defp enc({:obj, pairs}, level) do
    inner =
      Enum.map_join(pairs, ",\n", fn {k, v} ->
        ind(level + 1) <> JSON.encode!(k) <> ": " <> enc(v, level + 1)
      end)

    "{\n" <> inner <> "\n" <> ind(level) <> "}"
  end

  defp enc([], _level), do: "[]"

  defp enc(list, level) when is_list(list) do
    inner = Enum.map_join(list, ",\n", fn item -> ind(level + 1) <> enc(item, level + 1) end)
    "[\n" <> inner <> "\n" <> ind(level) <> "]"
  end

  defp enc(scalar, _level), do: JSON.encode!(scalar)

  defp ind(n), do: String.duplicate("  ", n)

  defp summarize(events, dropped, last_touched, out) do
    by_kind =
      Enum.reduce(events, %{}, fn {:obj, pairs}, acc ->
        {_, kind} = Enum.find(pairs, fn {k, _} -> k == "kind" end)
        Map.update(acc, kind, 1, &(&1 + 1))
      end)

    IO.puts("events kept     : #{length(events)}")
    IO.puts("  by kind       : #{inspect(by_kind)}")
    IO.puts("dropped (touch) : #{dropped} deltas")
    IO.puts("last_touched_at : #{last_touched}")
    IO.puts("wrote           : #{Path.relative_to_cwd(out)}")
  end

  # ---- argv driver ----------------------------------------------------------
  def main(argv) do
    case argv do
      [source, entity | rest] ->
        {raw, out} =
          case rest do
            [] -> {nil, nil}
            [raw] -> {raw, nil}
            [raw, out | _] -> {raw, out}
          end

        run(source, String.to_integer(entity), raw, out)

      _ ->
        IO.puts(:stderr, """
        usage: mix run test/ingest/fixtures/gen.exs <source_system> <entity_id> [<raw_path> [<out_path>]]
          e.g. mix run test/ingest/fixtures/gen.exs medipim-be 422156
               mix run test/ingest/fixtures/gen.exs medipim-fr 347025
        """)

        System.halt(1)
    end
  end
end

# Auto-run only when invoked directly with args (e.g. `mix run … gen.exs medipim-fr 347025`).
# When `gen_422156.exs` `Code.require_file`s this file as a library, argv is empty, so this is a
# no-op and the wrapper drives `Gen.run/2` itself — keeping the module reusable, not self-running.
if System.argv() != [], do: Gen.main(System.argv())
