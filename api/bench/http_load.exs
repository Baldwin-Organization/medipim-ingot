# Twice-peak pilot load check against a running release.
#
# Pilot assumption: 50 current reads/s and one source refresh/s. This check runs twice that load.
#   API_BASE=http://localhost:4000 mix run --no-start bench/http_load.exs

base = System.get_env("API_BASE", "http://localhost:4000")
token = System.get_env("PRODUCT_API_TOKEN", "local-product-token-change-me-000001")
seconds = String.to_integer(System.get_env("LOAD_SECONDS", "10"))
reads_per_second = 100
writes_per_second = 2
run_id = System.system_time(:millisecond)

uri = URI.parse(base)
host = uri.host
port = uri.port || 80

receive_all = fn receive_all, socket, acc ->
  case :gen_tcp.recv(socket, 0, 5_000) do
    {:ok, chunk} -> receive_all.(receive_all, socket, [chunk | acc])
    {:error, :closed} -> acc |> Enum.reverse() |> IO.iodata_to_binary()
    {:error, _reason} -> ""
  end
end

request = fn method, path, body ->
  payload = if body, do: JSON.encode!(body), else: ""

  wire =
    [
      method |> Atom.to_string() |> String.upcase(),
      " ",
      path,
      " HTTP/1.1\r\nHost: ",
      host,
      "\r\nAuthorization: Bearer ",
      token,
      "\r\nConnection: close\r\n",
      if(body, do: "Content-Type: application/json\r\n", else: ""),
      "Content-Length: ",
      Integer.to_string(byte_size(payload)),
      "\r\n\r\n",
      payload
    ]

  {microseconds, response} =
    :timer.tc(fn ->
      with {:ok, socket} <-
             :gen_tcp.connect(String.to_charlist(host), port, [:binary, active: false]),
           :ok <- :gen_tcp.send(socket, wire) do
        receive_all.(receive_all, socket, [])
      else
        _ -> ""
      end
    end)

  status =
    case Regex.run(~r/^HTTP\/1\.1 ([0-9]{3})/, response) do
      [_, code] -> String.to_integer(code)
      _ -> 0
    end

  {microseconds, status}
end

{_, 200} =
  request.(:post, "/v1/claims", %{
    claims: [
      %{kind: "identity", source: "load", ref: "seed", codes: ["cnk:9999999"]},
      %{kind: "grouping", source: "load", code: "cnk:9999999", product: 1}
    ]
  })

measurements =
  Enum.flat_map(1..seconds, fn second ->
    started = System.monotonic_time(:millisecond)

    operations =
      List.duplicate({:get, "/v1/products/1", nil}, reads_per_second) ++
        Enum.map(1..writes_per_second, fn write ->
          ref = "load-#{run_id}-#{second}-#{write}"

          {:put, "/v1/source-records/load/#{ref}/revisions/1",
           %{
             operation: "replace",
             claims: [
               %{kind: "identity", codes: ["supplier_ref:#{ref}"]},
               %{kind: "attribute", code: "supplier_ref:#{ref}", field: "name", value: ref}
             ]
           }}
        end)

    results =
      operations
      |> Task.async_stream(
        fn {method, path, body} -> request.(method, path, body) end,
        max_concurrency: 50,
        timeout: 10_000,
        ordered: false
      )
      |> Enum.map(fn {:ok, result} -> result end)

    remaining = 1_000 - (System.monotonic_time(:millisecond) - started)
    if remaining > 0, do: Process.sleep(remaining)
    results
  end)

latencies = measurements |> Enum.map(&elem(&1, 0)) |> Enum.sort()
errors = Enum.count(measurements, &(elem(&1, 1) != 200))
p95 = Enum.at(latencies, floor(length(latencies) * 0.95)) / 1_000
maximum = List.last(latencies) / 1_000

report = %{
  seconds: seconds,
  reads_per_second: reads_per_second,
  writes_per_second: writes_per_second,
  requests: length(measurements),
  errors: errors,
  p95_ms: p95,
  max_ms: maximum
}

IO.puts(JSON.encode!(report))

if errors > 0 or p95 > 250 do
  raise "twice-peak load target failed"
end
