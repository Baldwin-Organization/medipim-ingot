defmodule Api.Health do
  @moduledoc false
  import Plug.Conn

  def respond(conn) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, JSON.encode!(%{status: "ok"}))
  end

  def ready(conn) do
    {status, body} =
      case Postgrex.query(
             Api.DB,
             """
             SELECT
               to_regclass('public.events') IS NOT NULL,
               to_regclass('public.golden_records') IS NOT NULL
             """,
             [],
             timeout: 2_000
           ) do
        {:ok, %{rows: [[true, true]]}} ->
          event_offset = current_offset()
          projection_offset = Api.ReadModels.checkpoint_offset()

          if event_offset == projection_offset do
            {200,
             %{
               status: "ready",
               db: true,
               event_offset: event_offset,
               projection_offset: projection_offset
             }}
          else
            {503,
             %{
               status: "not_ready",
               db: true,
               event_offset: event_offset,
               projection_offset: projection_offset
             }}
          end

        {:ok, _} ->
          {503, %{status: "not_ready", db: true}}

        {:error, _} ->
          {503, %{status: "not_ready", db: false}}
      end

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, JSON.encode!(body))
  end

  defp current_offset do
    case Postgrex.query(
           Api.DB,
           ~s|SELECT COALESCE(max("offset"), 0) FROM events|,
           []
         ) do
      {:ok, %{rows: [[offset]]}} -> offset
      _ -> 0
    end
  end

  def not_found(conn) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(404, JSON.encode!(%{error: "not found"}))
  end
end

defmodule Api.Router do
  @moduledoc """
  The default front door (single-listener mode): `/health` (unauthenticated, for Docker/Dokploy
  checks), the Product API under `/v1`, the Steward surface under `/steward`. With `STEWARD_PORT`
  set, `Api.PublicRouter` + `Api.StewardSite` replace this one — same paths, separate listeners.
  """
  use Plug.Router

  plug(Plug.RequestId)
  plug(Api.RequestLogger)
  plug(:match)
  plug(:dispatch)

  get("/health", do: Api.Health.respond(conn))
  get("/ready", do: Api.Health.ready(conn))
  forward("/v1", to: Api.ProductRouter)
  forward("/steward", to: Api.StewardRouter)
  match(_, do: Api.Health.not_found(conn))
end

defmodule Api.PublicRouter do
  @moduledoc "The main listener when the steward surface is split onto its own port — no `/steward` here."
  use Plug.Router

  plug(Plug.RequestId)
  plug(Api.RequestLogger)
  plug(:match)
  plug(:dispatch)

  get("/health", do: Api.Health.respond(conn))
  get("/ready", do: Api.Health.ready(conn))
  forward("/v1", to: Api.ProductRouter)
  match(_, do: Api.Health.not_found(conn))
end

defmodule Api.StewardSite do
  @moduledoc "The steward listener (`STEWARD_PORT`): same `/steward` paths, its own port."
  use Plug.Router

  plug(Plug.RequestId)
  plug(Api.RequestLogger)
  plug(:match)
  plug(:dispatch)

  get("/health", do: Api.Health.respond(conn))
  get("/ready", do: Api.Health.ready(conn))
  forward("/steward", to: Api.StewardRouter)
  match(_, do: Api.Health.not_found(conn))
end
