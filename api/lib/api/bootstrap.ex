defmodule Api.Bootstrap do
  @moduledoc """
  Ordered startup gate.

  `start_link/1` does not return until database migrations and projection recovery finish, so the
  supervisor cannot start HTTP listeners against a partially migrated schema.
  """
  use GenServer
  require Logger

  def start_link(_opts), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  @impl true
  def init(:ok) do
    started = System.monotonic_time()
    Api.Store.migrate_when_ready!()
    recover_projections!()

    elapsed_ms =
      (System.monotonic_time() - started)
      |> System.convert_time_unit(:native, :millisecond)

    Logger.info("database ready",
      offset: Api.ReadModels.checkpoint_offset(),
      elapsed_ms: elapsed_ms
    )

    {:ok, %{}}
  end

  defp recover_projections! do
    event_offset =
      case Postgrex.query!(
             Api.DB,
             ~s|SELECT COALESCE(max("offset"), 0) FROM events|,
             []
           ) do
        %{rows: [[offset]]} -> offset
      end

    if Api.ReadModels.checkpoint_offset() != event_offset do
      case Api.Store.rebuild!() do
        {:ok, {status, ^event_offset}} when status in [:ok, :repaired] -> :ok
        result -> raise "projection recovery failed: #{inspect(result)}"
      end
    end
  end
end
