# Twice-pilot-volume indexed-read check.
#
# Run with the test database container available:
#   MIX_ENV=test mix run bench/read_models.exs

count = 200_000
payload = Api.Codec.encode!(%{key: "BENCH", codes: ["cnk:1"], attributes: [], media: []})

result =
  Postgrex.transaction(
    Api.DB,
    fn conn ->
      Postgrex.query!(conn, "CREATE TEMP TABLE golden_records (LIKE public.golden_records INCLUDING ALL)", [])
      Postgrex.query!(conn, "CREATE TEMP TABLE legacy_ownership (LIKE public.legacy_ownership INCLUDING ALL)", [])
      Postgrex.query!(conn, "CREATE TEMP TABLE redirects (LIKE public.redirects INCLUDING ALL)", [])
      Postgrex.query!(conn, "CREATE TEMP TABLE code_ownership (LIKE public.code_ownership INCLUDING ALL)", [])

      Postgrex.query!(
        conn,
        """
        INSERT INTO golden_records (key, legacy_id, payload)
        SELECT 'BENCH_' || n, n, convert_from($1, 'UTF8')::jsonb
        FROM generate_series(1, $2) AS n
        """,
        [payload, count],
        timeout: 120_000
      )

      Postgrex.query!(
        conn,
        """
        INSERT INTO legacy_ownership (legacy_id, key)
        SELECT n, 'BENCH_' || n
        FROM generate_series(1, $1) AS n
        """,
        [count],
        timeout: 120_000
      )

      Postgrex.query!(
        conn,
        """
        INSERT INTO code_ownership (scheme, value, key)
        SELECT 'cnk', n::text, 'BENCH_' || n
        FROM generate_series(1, $1) AS n
        """,
        [count],
        timeout: 120_000
      )

      ids = for i <- 1..100, do: rem(i * 7_919, count) + 1

      timings =
        Enum.map(ids, fn id ->
          {microseconds, {:ok, _view, _original, _current}} =
            :timer.tc(Api.ReadModels, :golden_by_legacy, [id, conn])

          microseconds
        end)

      {code_microseconds, {:ok, [_view]}} =
        :timer.tc(Api.ReadModels, :golden_by_code, [:cnk, Integer.to_string(count), conn])

      sorted = Enum.sort(timings)

      %{
        records: count,
        median_ms: Enum.at(sorted, 49) / 1_000,
        p95_ms: Enum.at(sorted, 94) / 1_000,
        max_ms: List.last(sorted) / 1_000,
        code_lookup_ms: code_microseconds / 1_000
      }
    end,
    timeout: 120_000
  )

{:ok, measurements} = result
IO.puts(JSON.encode!(measurements))

if measurements.p95_ms > 50 or measurements.code_lookup_ms > 50 do
  raise "indexed reads exceeded the 50 ms pilot target"
end
