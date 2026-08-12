import Config

config :logger, level: :warning

config :golden_record_api,
  # no HTTP listener in tests — Plug.Test drives the routers directly
  server: false,
  db: [
    hostname: System.get_env("PGHOST", "localhost"),
    port: String.to_integer(System.get_env("PGPORT", "55432")),
    username: System.get_env("PGUSER", "postgres"),
    password: System.get_env("PGPASSWORD", "postgres"),
    database: System.get_env("PGDATABASE", "golden_record_api_test")
  ],
  product_token: "test-product-token",
  csrf_secret: "test-csrf-secret",
  steward_credentials: %{
    "sam" => %{bearer: ["test-steward-token", "test-sam-second-token"], password: "sam-password"},
    "alex" => %{bearer: ["test-alex-token"], password: "alex-password"},
    "kim" => %{bearer: ["test-kim-token"], password: "kim-password"}
  }
