defmodule Api.Application do
  @moduledoc """
  Supervision: a Postgrex pool (the only runtime state — connections) and the Bandit listener(s).
  With `STEWARD_PORT` set, the steward surface binds its own listener and the main listener stops
  serving `/steward` — network-level separation without a second service.
  """
  use Application

  @impl true
  def start(_type, _args) do
    children = [{Postgrex, db_opts()} | bootstrap() ++ listeners()]
    Supervisor.start_link(children, strategy: :one_for_one, name: Api.Supervisor)
  end

  # GenServer init blocks its start_link until migration completes. Because supervisors start
  # children in list order, no listener can bind before this child reports success.
  defp bootstrap do
    if Application.fetch_env!(:golden_record_api, :server),
      do: [Api.Bootstrap],
      else: []
  end

  defp db_opts do
    Application.fetch_env!(:golden_record_api, :db)
    |> Keyword.merge(name: Api.DB, pool_size: 10)
  end

  defp listeners do
    if Application.fetch_env!(:golden_record_api, :server) do
      port = Application.fetch_env!(:golden_record_api, :port)

      case Application.fetch_env!(:golden_record_api, :steward_port) do
        nil ->
          [{Bandit, plug: Api.Router, port: port}]

        steward_port ->
          [
            {Bandit, plug: Api.PublicRouter, port: port},
            {Bandit, plug: Api.StewardSite, port: steward_port}
          ]
      end
    else
      []
    end
  end
end
