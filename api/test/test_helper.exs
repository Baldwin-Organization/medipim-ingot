# Ensure the test database exists (the app's pool may have started before it did), then wait for
# the pool to connect. Needs a reachable Postgres — locally: the gr-api-test-pg container
# (docker run -d --name gr-api-test-pg -e POSTGRES_PASSWORD=postgres -p 55432:5432 postgres:16-alpine);
# in CI: the postgres service.
db = Application.fetch_env!(:golden_record_api, :db)

{:ok, admin} = db |> Keyword.put(:database, "postgres") |> Postgrex.start_link()

case Postgrex.query(admin, ~s(CREATE DATABASE "#{db[:database]}"), []) do
  {:ok, _} -> :ok
  # 42P04 duplicate_database — already there, fine
  {:error, %Postgrex.Error{postgres: %{code: :duplicate_database}}} -> :ok
end

GenServer.stop(admin)

# the app's pool reconnects via backoff; give it a moment
unless Enum.any?(1..50, fn _ ->
         match?({:ok, _}, Postgrex.query(Api.DB, "SELECT 1", [])) || (Process.sleep(100) && false)
       end) do
  raise "test database never became reachable through the app pool"
end

Api.Store.migrate!()
{:ok, :ok} = Api.Store.reset!()

ExUnit.start()
