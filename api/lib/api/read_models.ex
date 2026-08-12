defmodule Api.ReadModels do
  @moduledoc """
  Rebuildable, indexed Postgres projections.

  Rows are scoped to a claim, key, code, source record, review case, or other natural projection
  key. Nothing here is authoritative: `Api.Store.rebuild!/0` can truncate every table and recreate
  it from the JSON event log.
  """

  @tables ~w(
    projection_entries review_cases tombstones source_record_views edges golden_records redirects
    legacy_ownership code_ownership identity_members current_claims projection_checkpoints
  )

  def migrate!(conn) do
    statements()
    |> Enum.each(&Postgrex.query!(conn, &1, []))
  end

  def reset!(conn) do
    Postgrex.query!(conn, "TRUNCATE " <> Enum.join(@tables, ", "), [])
    :ok
  end

  def replace!(conn, %Api.State{} = state) do
    log = Api.Store.log(conn)

    reset!(conn)
    insert_checkpoint(conn, state)
    insert_claims(conn, state)
    insert_members(conn, state)
    insert_legacy_ownership(conn, state)
    insert_redirects(conn, state)
    insert_review_cases(conn, state)
    insert_entries(conn, state)
    insert_edges(conn, state)
    insert_tombstones(conn, state)
    insert_source_record_views(conn, log)
    insert_golden_records(conn, state, log)
    :ok
  end

  def load(conn) do
    case checkpoint(conn) do
      nil ->
        nil

      %{offset: offset, ledger: ledger} ->
        review_cases = load_review_cases(conn)

        %Api.State{
          ledger: %IdentityLedger{
            members: load_members(conn),
            next: ledger.next,
            prefix: ledger.prefix,
            next_by_prefix: ledger.next_by_prefix
          },
          current: load_claims(conn),
          flags: load_list_entries(conn, "flags"),
          resolved: load_set_entries(conn, "resolved"),
          overrides: %{
            attr: load_map_entries(conn, "overrides_attr"),
            product: load_map_entries(conn, "overrides_product")
          },
          assigned: load_legacy_ownership(conn),
          shared: load_set_entries(conn, "shared"),
          redirects: load_redirects(conn),
          proposals: load_map_entries(conn, "proposals"),
          source_records: load_map_entries(conn, "source_records"),
          source_record_revisions: load_map_entries(conn, "source_record_revisions"),
          record_keys: load_map_entries(conn, "record_keys"),
          review_cases: review_cases,
          active_case_by_subject:
            review_cases
            |> Enum.filter(fn {_id, review} -> review.status == :open end)
            |> Map.new(fn {id, review} -> {review.subject, id} end),
          offset: offset
        }
    end
  end

  def golden_by_legacy(legacy_id, conn \\ Api.DB) do
    case Postgrex.query!(
           conn,
           """
           WITH RECURSIVE identity_path(key, depth) AS (
             SELECT key, 0 FROM legacy_ownership WHERE legacy_id = $1
             UNION ALL
             SELECT r.to_key, p.depth + 1
             FROM identity_path p
             JOIN redirects r ON r.from_key = p.key
           )
           SELECT g.payload::text, first.key, last.key
           FROM (SELECT key FROM identity_path ORDER BY depth ASC LIMIT 1) first
           CROSS JOIN (SELECT key FROM identity_path ORDER BY depth DESC LIMIT 1) last
           JOIN golden_records g ON g.key = last.key
           """,
           [legacy_id]
         ) do
      %{rows: [[payload, original, current]]} ->
        {:ok, Api.Codec.decode!(payload), original, current}

      %{rows: []} ->
        :not_found
    end
  end

  def golden_by_code(scheme, value, conn \\ Api.DB) do
    %{rows: rows} =
      Postgrex.query!(
        conn,
        """
        SELECT DISTINCT g.payload::text
        FROM code_ownership o
        JOIN golden_records g ON g.key = o.key
        WHERE o.scheme = $1 AND o.value = $2
        ORDER BY g.payload::text
        """,
        [to_string(scheme), value]
      )

    case Enum.map(rows, fn [payload] -> Api.Codec.decode!(payload) end) do
      [] -> :not_found
      records -> {:ok, Enum.sort_by(records, & &1.key)}
    end
  end

  def source_record(source, ref, conn \\ Api.DB) do
    case Postgrex.query!(
           conn,
           """
           SELECT payload::text
           FROM source_record_views
           WHERE source = $1 AND ref = $2
           """,
           [source, ref]
         ) do
      %{rows: [[payload]]} -> {:ok, Api.Codec.decode!(payload)}
      %{rows: []} -> :not_found
    end
  end

  def source_record_key(source, ref, lane, conn \\ Api.DB),
    do: load_one_entry(conn, "record_keys", {source, ref, lane})

  def resolve_key(key, conn \\ Api.DB)
  def resolve_key(nil, _conn), do: nil

  def resolve_key(key, conn) do
    %{rows: [[resolved]]} =
      Postgrex.query!(
        conn,
        """
        WITH RECURSIVE identity_path(key, depth) AS (
          VALUES ($1::text, 0)
          UNION ALL
          SELECT r.to_key, p.depth + 1
          FROM identity_path p
          JOIN redirects r ON r.from_key = p.key
        )
        SELECT key FROM identity_path ORDER BY depth DESC LIMIT 1
        """,
        [key]
      )

    resolved
  end

  def legacy_for_key(key, conn \\ Api.DB)
  def legacy_for_key(nil, _conn), do: nil

  def legacy_for_key(key, conn) do
    case Postgrex.query!(
           conn,
           "SELECT legacy_id FROM legacy_ownership WHERE key = $1 ORDER BY legacy_id LIMIT 1",
           [key]
         ) do
      %{rows: [[legacy_id]]} -> legacy_id
      %{rows: []} -> nil
    end
  end

  def identity(key, conn \\ Api.DB) do
    current = resolve_key(key, conn)

    %{rows: code_rows} =
      Postgrex.query!(
        conn,
        """
        SELECT scheme, value
        FROM identity_members
        WHERE key = $1
        ORDER BY scheme, value
        """,
        [current]
      )

    %{rows: legacy_rows} =
      Postgrex.query!(
        conn,
        """
        WITH RECURSIVE ancestors(key) AS (
          VALUES ($1::text)
          UNION
          SELECT r.from_key
          FROM redirects r
          JOIN ancestors a ON r.to_key = a.key
        )
        SELECT legacy_id
        FROM legacy_ownership
        WHERE key IN (SELECT key FROM ancestors)
        ORDER BY legacy_id
        """,
        [current]
      )

    tombstoned? =
      match?(
        %{rows: [[true]]},
        Postgrex.query!(
          conn,
          "SELECT EXISTS(SELECT 1 FROM tombstones WHERE key = $1)",
          [current]
        )
      )

    status =
      cond do
        current != key -> "merged"
        code_rows != [] -> "active"
        tombstoned? -> "withdrawn"
        true -> "unknown"
      end

    %{
      key: key,
      current_key: current,
      status: status,
      lane: current && Lanes.lane_of_key(current),
      codes: Enum.map(code_rows, fn [scheme, value] -> "#{scheme}:#{value}" end),
      legacy_ids: Enum.map(legacy_rows, &hd/1)
    }
  end

  def checkpoint_offset(conn \\ Api.DB) do
    case checkpoint(conn) do
      nil -> 0
      %{offset: offset} -> offset
    end
  end

  def effective_on(conn \\ Api.DB) do
    case checkpoint(conn) do
      nil -> nil
      %{effective_on: effective_on} -> effective_on
    end
  end

  defp statements do
    [
      """
      CREATE TABLE IF NOT EXISTS projection_checkpoints (
        name text PRIMARY KEY,
        "offset" bigint NOT NULL,
        effective_on date,
        payload jsonb NOT NULL,
        updated_at timestamptz NOT NULL DEFAULT now()
      )
      """,
      "ALTER TABLE projection_checkpoints ADD COLUMN IF NOT EXISTS effective_on date",
      """
      CREATE TABLE IF NOT EXISTS current_claims (
        slot_key text PRIMARY KEY,
        kind text NOT NULL,
        source text NOT NULL,
        valid_from date,
        valid_to date,
        recorded_at timestamptz NOT NULL,
        payload jsonb NOT NULL
      )
      """,
      "CREATE INDEX IF NOT EXISTS current_claims_kind_source_idx ON current_claims (kind, source)",
      """
      CREATE TABLE IF NOT EXISTS identity_members (
        key text NOT NULL,
        scheme text NOT NULL,
        value text NOT NULL,
        PRIMARY KEY (key, scheme, value)
      )
      """,
      "CREATE INDEX IF NOT EXISTS identity_members_code_idx ON identity_members (scheme, value)",
      """
      CREATE TABLE IF NOT EXISTS code_ownership (
        scheme text NOT NULL,
        value text NOT NULL,
        key text NOT NULL,
        PRIMARY KEY (scheme, value, key)
      )
      """,
      "CREATE INDEX IF NOT EXISTS code_ownership_key_idx ON code_ownership (key)",
      """
      CREATE TABLE IF NOT EXISTS legacy_ownership (
        legacy_id bigint PRIMARY KEY,
        key text NOT NULL
      )
      """,
      "CREATE INDEX IF NOT EXISTS legacy_ownership_key_idx ON legacy_ownership (key)",
      """
      CREATE TABLE IF NOT EXISTS redirects (
        from_key text PRIMARY KEY,
        to_key text NOT NULL
      )
      """,
      """
      CREATE TABLE IF NOT EXISTS golden_records (
        key text PRIMARY KEY,
        legacy_id bigint,
        payload jsonb NOT NULL
      )
      """,
      "CREATE UNIQUE INDEX IF NOT EXISTS golden_records_legacy_idx ON golden_records (legacy_id) WHERE legacy_id IS NOT NULL",
      """
      CREATE TABLE IF NOT EXISTS edges (
        slot_key text PRIMARY KEY,
        from_scheme text NOT NULL,
        from_value text NOT NULL,
        relation text NOT NULL,
        to_scheme text NOT NULL,
        to_value text NOT NULL,
        payload jsonb NOT NULL
      )
      """,
      "CREATE INDEX IF NOT EXISTS edges_from_idx ON edges (from_scheme, from_value, relation)",
      "CREATE INDEX IF NOT EXISTS edges_to_idx ON edges (to_scheme, to_value, relation)",
      """
      CREATE TABLE IF NOT EXISTS tombstones (
        source text NOT NULL,
        ref text NOT NULL,
        key text,
        payload jsonb NOT NULL,
        PRIMARY KEY (source, ref)
      )
      """,
      "CREATE INDEX IF NOT EXISTS tombstones_key_idx ON tombstones (key)",
      """
      CREATE TABLE IF NOT EXISTS source_record_views (
        source text NOT NULL,
        ref text NOT NULL,
        payload jsonb NOT NULL,
        PRIMARY KEY (source, ref)
      )
      """,
      """
      CREATE TABLE IF NOT EXISTS review_cases (
        case_id text PRIMARY KEY,
        subject_key text NOT NULL,
        status text NOT NULL,
        evidence_offset bigint NOT NULL,
        payload jsonb NOT NULL
      )
      """,
      "CREATE INDEX IF NOT EXISTS review_cases_subject_status_idx ON review_cases (subject_key, status)",
      """
      CREATE TABLE IF NOT EXISTS projection_entries (
        section text NOT NULL,
        entity_key text NOT NULL,
        payload jsonb NOT NULL,
        PRIMARY KEY (section, entity_key)
      )
      """,
      "CREATE INDEX IF NOT EXISTS projection_entries_section_idx ON projection_entries (section)"
    ]
  end

  defp insert_checkpoint(conn, state) do
    payload =
      Api.Codec.encode!(%{
        next: state.ledger.next,
        prefix: state.ledger.prefix,
        next_by_prefix: state.ledger.next_by_prefix
      })

    Postgrex.query!(
      conn,
      """
      INSERT INTO projection_checkpoints (name, "offset", effective_on, payload)
      VALUES ('main', $1, $2, convert_from($3, 'UTF8')::jsonb)
      """,
      [state.offset, Date.utc_today(), payload]
    )
  end

  defp checkpoint(conn) do
    case Postgrex.query!(
           conn,
           """
           SELECT "offset", effective_on, payload::text
           FROM projection_checkpoints
           WHERE name = 'main'
           """,
           []
         ) do
      %{rows: [[offset, effective_on, payload]]} ->
        decoded = Api.Codec.decode!(payload)
        %{offset: offset, effective_on: effective_on, ledger: decoded}

      %{rows: []} ->
        nil
    end
  end

  defp insert_claims(conn, state) do
    rows =
      Enum.map(state.current, fn {slot, claim} ->
        [
          digest(slot),
          to_string(claim.kind),
          to_string(claim.source),
          claim.valid_from && Bitemporal.effective_date(claim.valid_from),
          claim.valid_to && Bitemporal.effective_date(claim.valid_to),
          Bitemporal.to_datetime(claim.recorded_at),
          Api.Codec.encode!({slot, claim})
        ]
      end)

    insert_batches(conn, rows, fn columns ->
      Postgrex.query!(
        conn,
        """
        INSERT INTO current_claims
          (slot_key, kind, source, valid_from, valid_to, recorded_at, payload)
        SELECT slot_key, kind, source, valid_from, valid_to, recorded_at, payload::jsonb
        FROM unnest(
          $1::text[], $2::text[], $3::text[], $4::date[], $5::date[],
          $6::timestamptz[], $7::text[]
        ) AS rows(slot_key, kind, source, valid_from, valid_to, recorded_at, payload)
        """,
        columns
      )
    end)
  end

  defp insert_members(conn, state) do
    rows =
      for {key, codes} <- state.ledger.members,
          {scheme, value} <- codes,
          do: [key, to_string(scheme), value]

    insert_simple(conn, "identity_members", "(key, scheme, value)", rows, 3)
    insert_simple(conn, "code_ownership", "(key, scheme, value)", rows, 3)
  end

  defp insert_legacy_ownership(conn, state) do
    rows = Enum.map(state.assigned, fn {key, legacy_id} -> [legacy_id, key] end)
    insert_simple(conn, "legacy_ownership", "(legacy_id, key)", rows, 2, ["bigint", "text"])
  end

  defp insert_redirects(conn, state) do
    rows = Enum.map(state.redirects, fn {from, to} -> [from, to] end)
    insert_simple(conn, "redirects", "(from_key, to_key)", rows, 2)
  end

  defp insert_review_cases(conn, state) do
    rows =
      Enum.map(state.review_cases, fn {id, review} ->
        [
          id,
          digest(review.subject),
          inspect(review.status),
          review.evidence_offset,
          Api.Codec.encode!({id, review})
        ]
      end)

    insert_batches(conn, rows, fn columns ->
      Postgrex.query!(
        conn,
        """
        INSERT INTO review_cases (case_id, subject_key, status, evidence_offset, payload)
        SELECT case_id, subject_key, status, evidence_offset, payload::jsonb
        FROM unnest($1::text[], $2::text[], $3::text[], $4::bigint[], $5::text[])
          AS rows(case_id, subject_key, status, evidence_offset, payload)
        """,
        columns
      )
    end)
  end

  defp insert_entries(conn, state) do
    rows =
      list_entries("flags", state.flags) ++
        set_entries("resolved", state.resolved) ++
        map_entries("overrides_attr", state.overrides.attr) ++
        map_entries("overrides_product", state.overrides.product) ++
        set_entries("shared", state.shared) ++
        map_entries("proposals", state.proposals) ++
        map_entries("source_records", state.source_records) ++
        map_entries("source_record_revisions", state.source_record_revisions) ++
        map_entries("record_keys", state.record_keys)

    insert_batches(conn, rows, fn columns ->
      Postgrex.query!(
        conn,
        """
        INSERT INTO projection_entries (section, entity_key, payload)
        SELECT section, entity_key, payload::jsonb
        FROM unnest($1::text[], $2::text[], $3::text[])
          AS rows(section, entity_key, payload)
        """,
        columns
      )
    end)
  end

  defp insert_edges(conn, state) do
    rows =
      for {slot, %Events.ClaimAsserted{kind: :edge, data: data} = claim} <- state.current do
        {from_scheme, from_value} = data.from
        {to_scheme, to_value} = data.to

        [
          digest(slot),
          to_string(from_scheme),
          from_value,
          to_string(data.relation),
          to_string(to_scheme),
          to_value,
          Api.Codec.encode!(claim)
        ]
      end

    insert_batches(conn, rows, fn columns ->
      Postgrex.query!(
        conn,
        """
        INSERT INTO edges
          (slot_key, from_scheme, from_value, relation, to_scheme, to_value, payload)
        SELECT slot_key, from_scheme, from_value, relation, to_scheme, to_value, payload::jsonb
        FROM unnest(
          $1::text[], $2::text[], $3::text[], $4::text[], $5::text[], $6::text[], $7::text[]
        ) AS rows(slot_key, from_scheme, from_value, relation, to_scheme, to_value, payload)
        """,
        columns
      )
    end)
  end

  defp insert_tombstones(conn, state) do
    rows =
      for {{source, ref}, %Events.SourceRecordRevised{active: false} = record} <-
            state.source_records do
        key =
          state.record_keys
          |> Enum.find_value(fn
            {{^source, ^ref, _lane}, key} -> key
            _ -> nil
          end)

        [source, ref, key, Api.Codec.encode!(record)]
      end

    insert_batches(conn, rows, fn columns ->
      Postgrex.query!(
        conn,
        """
        INSERT INTO tombstones (source, ref, key, payload)
        SELECT source, ref, key, payload::jsonb
        FROM unnest($1::text[], $2::text[], $3::text[], $4::text[])
          AS rows(source, ref, key, payload)
        """,
        columns
      )
    end)
  end

  defp insert_source_record_views(conn, log) do
    now = DateTime.utc_now()
    today = Date.utc_today()

    rows =
      log
      |> Enum.filter(&match?(%Events.SourceRecordRevised{}, &1))
      |> Enum.filter(&Bitemporal.known?(&1, now))
      |> Enum.filter(&Bitemporal.effective?(&1, today))
      |> Enum.group_by(&{&1.source, &1.ref})
      |> Enum.map(fn {{source, ref}, revisions} ->
        record =
          Enum.max_by(revisions, &{Bitemporal.sort_key(&1.recorded_at), &1.order || -1})

        [source, ref, Api.Codec.encode!(record)]
      end)

    insert_batches(conn, rows, fn columns ->
      Postgrex.query!(
        conn,
        """
        INSERT INTO source_record_views (source, ref, payload)
        SELECT source, ref, payload::jsonb
        FROM unnest($1::text[], $2::text[], $3::text[])
          AS rows(source, ref, payload)
        """,
        columns
      )
    end)
  end

  defp insert_golden_records(conn, state, log) do
    temporal =
      History.state_bitemporal(log, DateTime.utc_now(), Date.utc_today())

    variants =
      temporal.members
      |> Catalog.project(temporal.claims, Api.Priority.current(), temporal.overrides)
      |> Enum.flat_map(& &1.variants)
      |> Map.new(&{&1.key, &1})

    active_keys =
      temporal.members
      |> Map.keys()
      |> Enum.filter(&(Lanes.lane_of_key(&1) == :product))
      |> MapSet.new()

    tombstoned_keys =
      state.assigned
      |> Map.keys()
      |> Enum.filter(fn key ->
        Api.State.follow(state, key) == key and not MapSet.member?(active_keys, key)
      end)
      |> MapSet.new()

    rows =
      active_keys
      |> MapSet.union(tombstoned_keys)
      |> Enum.map(fn key ->
        codes = Map.get(temporal.members, key, MapSet.new())

        view =
          case Map.get(variants, key) do
            nil ->
              %{
                key: key,
                codes: Enum.sort(codes) |> Enum.map(&Api.Views.code/1),
                attributes: [],
                media: []
              }

            variant ->
              Api.Views.variant(variant)
          end
          |> Map.put(
            :status,
            if(MapSet.member?(active_keys, key), do: "active", else: "withdrawn")
          )
          |> Map.put(:legacy_id, Map.get(state.assigned, key))

        [key, Map.get(state.assigned, key), Api.Codec.encode!(view)]
      end)

    insert_batches(conn, rows, fn columns ->
      Postgrex.query!(
        conn,
        """
        INSERT INTO golden_records (key, legacy_id, payload)
        SELECT key, legacy_id, payload::jsonb
        FROM unnest($1::text[], $2::bigint[], $3::text[])
          AS rows(key, legacy_id, payload)
        """,
        columns
      )
    end)
  end

  defp load_claims(conn) do
    %{rows: rows} =
      Postgrex.query!(conn, "SELECT payload::text FROM current_claims ORDER BY slot_key", [])

    Map.new(rows, fn [payload] -> Api.Codec.decode!(payload) end)
  end

  defp load_members(conn) do
    %{rows: rows} =
      Postgrex.query!(
        conn,
        "SELECT key, scheme, value FROM identity_members ORDER BY key, scheme, value",
        []
      )

    Enum.reduce(rows, %{}, fn [key, scheme, value], acc ->
      code = {existing_atom_or_string(scheme), value}
      Map.update(acc, key, MapSet.new([code]), &MapSet.put(&1, code))
    end)
  end

  defp load_legacy_ownership(conn) do
    %{rows: rows} =
      Postgrex.query!(conn, "SELECT legacy_id, key FROM legacy_ownership ORDER BY legacy_id", [])

    Map.new(rows, fn [legacy_id, key] -> {key, legacy_id} end)
  end

  defp load_redirects(conn) do
    %{rows: rows} =
      Postgrex.query!(conn, "SELECT from_key, to_key FROM redirects ORDER BY from_key", [])

    Map.new(rows, fn [from, to] -> {from, to} end)
  end

  defp load_review_cases(conn) do
    %{rows: rows} =
      Postgrex.query!(conn, "SELECT payload::text FROM review_cases ORDER BY case_id", [])

    Map.new(rows, fn [payload] -> Api.Codec.decode!(payload) end)
  end

  defp load_map_entries(conn, section) do
    entries(conn, section) |> Map.new(&Api.Codec.decode!/1)
  end

  defp load_set_entries(conn, section) do
    entries(conn, section)
    |> Enum.map(fn payload ->
      {value, true} = Api.Codec.decode!(payload)
      value
    end)
    |> MapSet.new()
  end

  defp load_list_entries(conn, section) do
    entries(conn, section)
    |> Enum.map(fn payload ->
      {_index, value} = Api.Codec.decode!(payload)
      value
    end)
  end

  defp load_one_entry(conn, section, key) do
    case Postgrex.query!(
           conn,
           """
           SELECT payload::text
           FROM projection_entries
           WHERE section = $1 AND entity_key = $2
           """,
           [section, digest(key)]
         ) do
      %{rows: [[payload]]} ->
        {^key, value} = Api.Codec.decode!(payload)
        value

      %{rows: []} ->
        nil
    end
  end

  defp entries(conn, section) do
    %{rows: rows} =
      Postgrex.query!(
        conn,
        """
        SELECT payload::text
        FROM projection_entries
        WHERE section = $1
        ORDER BY entity_key
        """,
        [section]
      )

    Enum.map(rows, &hd/1)
  end

  defp map_entries(section, map) do
    Enum.map(map, fn {key, value} ->
      [section, digest(key), Api.Codec.encode!({key, value})]
    end)
  end

  defp set_entries(section, set) do
    Enum.map(set, fn value ->
      [section, digest(value), Api.Codec.encode!({value, true})]
    end)
  end

  defp list_entries(section, list) do
    list
    |> Enum.with_index()
    |> Enum.map(fn {value, index} ->
      entity_key = index |> Integer.to_string() |> String.pad_leading(20, "0")
      [section, entity_key, Api.Codec.encode!({index, value})]
    end)
  end

  defp digest(term) do
    term
    |> Api.Codec.encode!()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.url_encode64(padding: false)
  end

  defp existing_atom_or_string(value) do
    String.to_existing_atom(value)
  rescue
    ArgumentError -> value
  end

  defp insert_simple(conn, table, columns_sql, rows, count, types \\ nil) do
    types = types || List.duplicate("text", count)
    names = Enum.map_join(1..count, ", ", &"v#{&1}")

    casts =
      types |> Enum.with_index(1) |> Enum.map_join(", ", fn {type, i} -> "$#{i}::#{type}[]" end)

    insert_batches(conn, rows, fn columns ->
      Postgrex.query!(
        conn,
        "INSERT INTO #{table} #{columns_sql} SELECT #{names} FROM unnest(#{casts}) AS rows(#{names})",
        columns
      )
    end)
  end

  defp insert_batches(_conn, [], _fun), do: :ok

  defp insert_batches(_conn, rows, fun) do
    rows
    |> Enum.chunk_every(5_000)
    |> Enum.each(fn chunk ->
      columns = chunk |> Enum.zip() |> Enum.map(&Tuple.to_list/1)
      fun.(columns)
    end)
  end
end
