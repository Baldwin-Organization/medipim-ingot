defmodule Api.ProductRouter do
  @moduledoc """
  The Product API — medipim's machine-to-machine surface (`PRODUCT_API_TOKEN`).

  Writes: `POST /backfill/envelopes` (contract-C, idempotent, finer-grained fold) and
  `POST /claims` (live engine-native claims). `POST /dry-run` takes the same body as `/claims`
  through the same pipeline uncommitted and answers with the migration report (gr-rlq).
  `POST /cutover` commits a migration batch with convergent re-run semantics and answers with
  the committed report (gr-w4l, `Api.Cutover`).
  """
  use Plug.Router

  plug(Api.Auth, :product)
  plug(:match)
  plug(Plug.Parsers, parsers: [:json], json_decoder: JSON, length: 25_000_000)
  plug(:dispatch)

  post "/backfill/envelopes" do
    case conn.body_params do
      %{"envelopes" => envelopes} ->
        limited(conn, envelopes, :envelopes, fn -> write(conn, Api.Writes.backfill(envelopes)) end)

      _ ->
        json(conn, 422, %{errors: [%{index: nil, error: ~s(body must be {"envelopes": [...]})}]})
    end
  end

  post "/claims" do
    case conn.body_params do
      %{"claims" => claims} ->
        limited(conn, claims, :claims, fn ->
          write(conn, Api.Writes.claims(claims, idempotency_key(conn)))
        end)

      _ ->
        json(conn, 422, %{errors: [%{index: nil, error: ~s(body must be {"claims": [...]})}]})
    end
  end

  put "/source-records/:source/:ref/revisions/:revision" do
    count =
      length(List.wrap(conn.body_params["claims"])) +
        length(List.wrap(conn.body_params["upsert"]))

    limited_count(conn, count, :claims, fn ->
      write(conn, Api.Writes.source_record(source, ref, revision, conn.body_params))
    end)
  end

  get "/source-records/:source/:ref" do
    conn = fetch_query_params(conn)

    result =
      if temporal_query?(conn) do
        with {:ok, known_at, effective_at} <- clocks(conn) do
          Api.Reads.source_record_at(source, ref, known_at, effective_at)
        end
      else
        Api.Reads.source_record(source, ref)
      end

    case result do
      {:ok, record} ->
        json(conn, 200, record)

      :not_found ->
        json(conn, 404, %{error: "unknown source record #{source}/#{ref}"})

      {:error, error} ->
        json(conn, 422, %{error: error})
    end
  end

  # The same body as /claims, COMMITTED with migration semantics (per-slot compaction,
  # convergent re-runs) — the committed report is the response; a rejected batch is 422.
  post "/cutover" do
    case conn.body_params do
      %{"claims" => claims} ->
        limited(conn, claims, :claims, fn -> write(conn, Api.Cutover.commit(claims)) end)

      _ ->
        json(conn, 422, %{errors: [%{index: nil, error: ~s(body must be {"claims": [...]})}]})
    end
  end

  # The same body as /claims, run through the same pipeline, committing NOTHING — the report is
  # the response (validation errors included), so the status is 200 either way.
  post "/dry-run" do
    case conn.body_params do
      %{"claims" => claims} ->
        limited(conn, claims, :claims, fn -> json(conn, 200, Api.DryRun.report(claims)) end)

      _ ->
        json(conn, 422, %{errors: [%{index: nil, error: ~s(body must be {"claims": [...]})}]})
    end
  end

  get "/products/by-code/:scheme/:value" do
    conn = fetch_query_params(conn)

    result =
      if temporal_query?(conn) do
        with {:ok, known_at, effective_at} <- clocks(conn) do
          Api.Reads.by_code_at(scheme, value, known_at, effective_at)
        end
      else
        Api.Reads.by_code(scheme, value)
      end

    case result do
      {:ok, body} -> json(conn, 200, body)
      :not_found -> json(conn, 404, %{error: "no product carries #{scheme}:#{value}"})
      {:error, error} -> json(conn, 422, %{error: error})
    end
  end

  get "/identities/:key" do
    Api.Store.refresh_if_needed!()
    identity = Api.ReadModels.identity(key)

    if identity.status == "unknown" do
      json(conn, 404, %{error: "unknown identity #{key}", code: "identity_not_found"})
    else
      json(conn, 200, identity)
    end
  end

  get "/metadata" do
    json(conn, 200, Api.Metadata.current())
  end

  get "/products/:legacy_id" do
    conn = fetch_query_params(conn)

    with {id, ""} <- Integer.parse(legacy_id) do
      case conn.query_params["as_of"] do
        nil ->
          result =
            if temporal_query?(conn) do
              with {:ok, known_at, effective_at} <- clocks(conn) do
                Api.Reads.product_at(id, known_at, effective_at)
              end
            else
              Api.Reads.product(id)
            end

          case result do
            {:ok, view} -> json(conn, 200, view)
            :not_found -> json(conn, 404, %{error: "unknown legacy id #{id}"})
            {:error, error} -> json(conn, 422, %{error: error})
          end

        raw ->
          case Date.from_iso8601(raw) do
            {:ok, date} ->
              case Api.Reads.product_as_of(id, date) do
                {:ok, view} ->
                  json(conn, 200, view)

                {:not_found_as_of, key} ->
                  json(conn, 404, %{error: "not resolvable as of #{raw}", key: key, as_of: raw})

                :not_found ->
                  json(conn, 404, %{error: "unknown legacy id #{id}"})
              end

            _ ->
              json(conn, 422, %{error: "as_of must be an ISO date, got #{inspect(raw)}"})
          end
      end
    else
      _ -> json(conn, 404, %{error: "legacy id must be an integer, got #{inspect(legacy_id)}"})
    end
  end

  get "/changes" do
    conn = fetch_query_params(conn)
    since = Integer.parse(conn.query_params["since"] || "0")
    limit = Integer.parse(conn.query_params["limit"] || "500")

    case {since, limit} do
      {{s, ""}, {l, ""}} when s >= 0 and l > 0 ->
        json(conn, 200, Api.Reads.changes(s, min(l, 1_000)))

      _ ->
        json(conn, 422, %{error: "since and limit must be non-negative integers"})
    end
  end

  match _ do
    json(conn, 404, %{error: "not found"})
  end

  defp write(conn, {:ok, summary}), do: json(conn, 200, summary)
  defp write(conn, {:error, {status, body}}), do: json(conn, status, body)

  defp idempotency_key(conn) do
    conn
    |> get_req_header("idempotency-key")
    |> List.first()
    |> case do
      nil -> nil
      "" -> nil
      key -> key
    end
  end

  defp limited(conn, items, kind, fun) when is_list(items) do
    limited_count(conn, length(items), kind, fun)
  end

  defp limited(_conn, _items, _kind, fun), do: fun.()

  defp limited_count(conn, count, kind, fun) do
    max = limit(kind)

    if count > max do
      json(conn, 413, %{
        error:
          "#{kind |> Atom.to_string() |> String.trim_trailing("s")} limit exceeded: #{count} > #{max}"
      })
    else
      fun.()
    end
  end

  defp limit(:claims), do: Application.get_env(:golden_record_api, :max_claims, 10_000)
  defp limit(:envelopes), do: Application.get_env(:golden_record_api, :max_envelopes, 1_000)

  defp clocks(conn) do
    with {:ok, known_at} <- known_at(conn.query_params["known_at"]),
         {:ok, effective_at} <- effective_at(conn.query_params["effective_at"]) do
      {:ok, known_at, effective_at}
    end
  end

  defp temporal_query?(conn),
    do: conn.query_params["known_at"] != nil or conn.query_params["effective_at"] != nil

  defp known_at(nil), do: {:ok, DateTime.utc_now()}

  defp known_at(raw) when is_binary(raw) do
    case DateTime.from_iso8601(raw) do
      {:ok, datetime, _offset} -> {:ok, datetime}
      _ -> {:error, "known_at must be an RFC3339 timestamp"}
    end
  end

  defp effective_at(nil), do: {:ok, Date.utc_today()}

  defp effective_at(raw) when is_binary(raw) do
    case Date.from_iso8601(raw) do
      {:ok, date} -> {:ok, date}
      _ -> {:error, "effective_at must be an ISO date"}
    end
  end

  defp json(conn, status, body) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, JSON.encode!(body))
  end
end
