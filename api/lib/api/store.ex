defmodule Api.Store do
  @moduledoc """
  The append-only JSON event store + disposable indexed projections.

  * `events` is the system of record: never updated, never deleted; `offset` is the engine's
    `order` made durable (assigned here, under the writer lock — not a serial, so the stored
    payload carries its own offset).
  * Per-key read tables hold claims, ownership, members, tombstones, redirects, golden records,
    edges, review cases, and a checkpoint. Append + projection happen in one transaction.
  * Projections are disposable: `rebuild!/0` folds every event without a fixed event cap,
    verifies the result, and recreates every indexed table.
  """
  require Logger

  @lock_key 726_001
  @migration_lock_key 726_002
  @foundation_version 20_260_710_01

  # ── schema ──────────────────────────────────────────────────────────────────
  def migrate!(conn \\ Api.DB) do
    case Postgrex.transaction(conn, fn migration_conn ->
           Postgrex.query!(
             migration_conn,
             """
             CREATE TABLE IF NOT EXISTS schema_migrations (
               version bigint PRIMARY KEY,
               applied_at timestamptz NOT NULL DEFAULT now()
             )
             """,
             []
           )

           Postgrex.query!(
             migration_conn,
             "SELECT pg_advisory_xact_lock($1)",
             [@migration_lock_key]
           )

           case Postgrex.query!(
                  migration_conn,
                  "SELECT 1 FROM schema_migrations WHERE version = $1",
                  [@foundation_version]
                ) do
             %{rows: []} ->
               migrate_foundation!(migration_conn)

               Postgrex.query!(
                 migration_conn,
                 "INSERT INTO schema_migrations (version) VALUES ($1)",
                 [@foundation_version]
               )

             %{rows: [[1]]} ->
               :ok
           end
         end) do
      {:ok, _} -> :ok
      {:error, reason} -> raise "database migration failed: #{inspect(reason)}"
    end
  end

  defp migrate_foundation!(conn) do
    Postgrex.query!(
      conn,
      """
      CREATE TABLE IF NOT EXISTS events (
        "offset"    bigint PRIMARY KEY,
        type        text   NOT NULL,
        recorded_at timestamptz NOT NULL,
        payload     jsonb  NOT NULL,
        inserted_at timestamptz NOT NULL DEFAULT now()
      )
      """,
      []
    )

    Postgrex.query!(
      conn,
      """
      DO $$
      BEGIN
        IF EXISTS (
          SELECT 1
          FROM information_schema.columns
          WHERE table_name = 'events'
            AND column_name = 'recorded_at'
            AND data_type = 'date'
        ) THEN
          ALTER TABLE events
          ALTER COLUMN recorded_at TYPE timestamptz
          USING recorded_at::timestamp AT TIME ZONE 'UTC';
        END IF;
      END
      $$;
      """,
      []
    )

    migrate_event_payload!(conn)
    migrate_event_intervals!(conn)
    Api.ReadModels.migrate!(conn)
    Postgrex.query!(conn, "DROP TABLE IF EXISTS snapshots", [])

    Postgrex.query!(
      conn,
      """
      CREATE TABLE IF NOT EXISTS backfill_seen (
        legacy_entity bigint NOT NULL,
        fingerprint   text   NOT NULL,
        inserted_at   timestamptz NOT NULL DEFAULT now(),
        PRIMARY KEY (legacy_entity, fingerprint)
      )
      """,
      []
    )

    Postgrex.query!(
      conn,
      """
      CREATE TABLE IF NOT EXISTS live_batches (
        idempotency_key text PRIMARY KEY,
        fingerprint     text  NOT NULL,
        response        bytea NOT NULL,
        inserted_at     timestamptz NOT NULL DEFAULT now()
      )
      """,
      []
    )

    :ok
  end

  @doc "Boot-time migrate with retry — the DB container may still be starting."
  def migrate_when_ready!(attempts \\ 60) do
    migrate!()
  rescue
    e ->
      if attempts > 1 do
        Process.sleep(500)
        migrate_when_ready!(attempts - 1)
      else
        reraise e, __STACKTRACE__
      end
  end

  # ── the single writer ───────────────────────────────────────────────────────
  @doc """
  Run `fun.(state, conn)` under the writer lock — `conn` lets the writer touch side tables
  (e.g. `backfill_seen`) in the SAME transaction. `fun` returns `{:ok, events, result}` — the
  events are appended (each stamped with its durable offset as `order`), folded into the state,
  and indexed projections stored transactionally — or `{:error, reason}` to roll back. Returns
  `{:ok, result}` / `{:error, reason}`.
  """
  def append(fun) do
    started = System.monotonic_time()

    result =
      Postgrex.transaction(
        Api.DB,
        fn conn ->
          Postgrex.query!(conn, "SELECT pg_advisory_xact_lock($1)", [@lock_key])
          state = load(conn)

          case fun.(state, conn) do
            {:ok, events, result} ->
              state = insert_and_fold(conn, state, events)
              Api.ReadModels.replace!(conn, state)
              result

            {:error, reason} ->
              Postgrex.rollback(conn, reason)
          end
        end,
        timeout: 60_000
      )

    emit(:append, started, result)
    result
  end

  @doc "The current state reconstructed from indexed rows plus any unprojected event tail."
  def state(conn \\ Api.DB), do: load(conn)

  @doc "Refresh date-sensitive current projections once when the effective calendar day changes."
  def refresh_if_needed! do
    if Api.ReadModels.effective_on() != Date.utc_today() do
      Postgrex.transaction(Api.DB, fn conn ->
        Postgrex.query!(conn, "SELECT pg_advisory_xact_lock($1)", [@lock_key])

        if Api.ReadModels.effective_on(conn) != Date.utc_today() do
          Api.ReadModels.replace!(conn, load(conn))
        end
      end)
    else
      :ok
    end
  end

  @doc "The full decoded log, offset order — for as-of projections and lineage."
  def log(conn \\ Api.DB) do
    %{rows: rows} =
      Postgrex.query!(conn, ~s(SELECT payload::text FROM events ORDER BY "offset"), [])

    Enum.map(rows, fn [json] -> Api.Codec.decode!(json) end)
  end

  @doc "Decoded events with offset > `offset` — the change feed."
  def events_since(offset, limit \\ 500, conn \\ Api.DB) do
    %{rows: rows} =
      Postgrex.query!(
        conn,
        ~s(SELECT payload::text FROM events WHERE "offset" > $1 ORDER BY "offset" LIMIT $2),
        [offset, limit]
      )

    Enum.map(rows, fn [json] -> Api.Codec.decode!(json) end)
  end

  @doc """
  Re-fold the entire log from offset zero and recreate every read table. Returns `{:ok, offset}`
  when the stored projections matched and `{:repaired, offset}` when they differed.
  """
  def rebuild! do
    started = System.monotonic_time()

    result =
      Postgrex.transaction(
        Api.DB,
        fn conn ->
          Postgrex.query!(conn, "SELECT pg_advisory_xact_lock($1)", [@lock_key])

          refolded = fold_tail(conn, Api.State.new())
          stored = Api.ReadModels.load(conn)
          Api.ReadModels.replace!(conn, refolded)

          if stored == nil or stored == refolded,
            do: {:ok, refolded.offset},
            else: {:repaired, refolded.offset}
        end,
        timeout: 300_000
      )

    emit(:rebuild, started, result)
    result
  end

  # ── internals ───────────────────────────────────────────────────────────────
  defp load(conn) do
    conn
    |> Api.ReadModels.load()
    |> Kernel.||(Api.State.new())
    |> then(&fold_tail(conn, &1))
  end

  defp insert_and_fold(conn, state, events) do
    Enum.reduce(events, state, fn event, s ->
      offset = s.offset + 1
      true = match?(%Date{}, event.recorded_at) or match?(%DateTime{}, event.recorded_at)
      stamped = %{event | order: offset}

      Postgrex.query!(
        conn,
        """
        INSERT INTO events
          ("offset", type, recorded_at, valid_from, valid_to, payload)
        VALUES
          ($1, $2, $3, $4, $5, convert_from($6, 'UTF8')::jsonb)
        """,
        [
          offset,
          Api.Codec.type(stamped),
          Bitemporal.to_datetime(stamped.recorded_at),
          stamped
          |> Map.get(:valid_from)
          |> Kernel.||(stamped.recorded_at)
          |> Bitemporal.effective_date(),
          stamped |> Map.get(:valid_to) |> effective_date_or_nil(),
          Api.Codec.encode!(stamped)
        ]
      )

      Api.State.apply_event(s, stamped)
    end)
  end

  defp fold_tail(conn, state) do
    %{rows: rows} =
      Postgrex.query!(
        conn,
        """
        SELECT payload::text
        FROM events
        WHERE "offset" > $1
        ORDER BY "offset"
        LIMIT 5000
        """,
        [state.offset]
      )

    next =
      Enum.reduce(rows, state, fn [json], current ->
        Api.State.apply_event(current, Api.Codec.decode!(json))
      end)

    if length(rows) == 5_000, do: fold_tail(conn, next), else: next
  end

  def reset! do
    Postgrex.transaction(Api.DB, fn conn ->
      Postgrex.query!(conn, "TRUNCATE events, backfill_seen, live_batches", [])
      Api.ReadModels.reset!(conn)
    end)
  end

  defp migrate_event_payload!(conn) do
    %{rows: [[type]]} =
      Postgrex.query!(
        conn,
        """
        SELECT data_type
        FROM information_schema.columns
        WHERE table_schema = current_schema()
          AND table_name = 'events'
          AND column_name = 'payload'
        """,
        []
      )

    if type == "bytea" do
      Postgrex.query!(conn, "ALTER TABLE events ADD COLUMN IF NOT EXISTS payload_json jsonb", [])

      %{rows: rows} =
        Postgrex.query!(
          conn,
          ~s(SELECT "offset", payload FROM events WHERE payload_json IS NULL ORDER BY "offset"),
          []
        )

      Enum.each(rows, fn [offset, payload] ->
        json = payload |> Api.Codec.decode_legacy!() |> Api.Codec.encode!()

        Postgrex.query!(
          conn,
          """
          UPDATE events
          SET payload_json = convert_from($2, 'UTF8')::jsonb
          WHERE "offset" = $1
          """,
          [offset, json]
        )
      end)

      Postgrex.query!(conn, "ALTER TABLE events ALTER COLUMN payload_json SET NOT NULL", [])
      Postgrex.query!(conn, "ALTER TABLE events DROP COLUMN payload", [])
      Postgrex.query!(conn, "ALTER TABLE events RENAME COLUMN payload_json TO payload", [])
    end
  end

  defp migrate_event_intervals!(conn) do
    Postgrex.query!(conn, "ALTER TABLE events ADD COLUMN IF NOT EXISTS valid_from date", [])
    Postgrex.query!(conn, "ALTER TABLE events ADD COLUMN IF NOT EXISTS valid_to date", [])

    %{rows: rows} =
      Postgrex.query!(
        conn,
        """
        SELECT "offset", recorded_at, payload::text
        FROM events
        WHERE valid_from IS NULL
        ORDER BY "offset"
        """,
        []
      )

    Enum.each(rows, fn [offset, recorded_at, payload] ->
      event = Api.Codec.decode!(payload)

      valid_from =
        event
        |> Map.get(:valid_from)
        |> Kernel.||(recorded_at)
        |> Bitemporal.effective_date()

      Postgrex.query!(
        conn,
        ~s(UPDATE events SET valid_from = $2, valid_to = $3 WHERE "offset" = $1),
        [offset, valid_from, event |> Map.get(:valid_to) |> effective_date_or_nil()]
      )
    end)

    Postgrex.query!(conn, "ALTER TABLE events ALTER COLUMN valid_from SET NOT NULL", [])

    Postgrex.query!(
      conn,
      """
      CREATE INDEX IF NOT EXISTS events_temporal_idx
      ON events (recorded_at, valid_from, valid_to)
      """,
      []
    )

    Postgrex.query!(
      conn,
      "CREATE INDEX IF NOT EXISTS events_type_offset_idx ON events (type, \"offset\")",
      []
    )
  end

  defp effective_date_or_nil(nil), do: nil
  defp effective_date_or_nil(value), do: Bitemporal.effective_date(value)

  defp emit(operation, started, result) do
    duration = System.monotonic_time() - started
    status = if match?({:ok, _}, result), do: :ok, else: :error

    :telemetry.execute(
      [:ingot, :store, operation],
      %{duration: duration},
      %{status: status}
    )

    Logger.info("store #{operation}",
      status: status,
      duration_ms: System.convert_time_unit(duration, :native, :millisecond)
    )
  end
end
