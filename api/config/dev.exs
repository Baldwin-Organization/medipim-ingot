import Config

config :golden_record_api,
  db: [
    hostname: System.get_env("PGHOST", "localhost"),
    port: String.to_integer(System.get_env("PGPORT", "55432")),
    username: System.get_env("PGUSER", "postgres"),
    password: System.get_env("PGPASSWORD", "postgres"),
    database: System.get_env("PGDATABASE", "golden_record_api_dev")
  ],
  # Empty credentials disable auth locally. Set values to exercise authentication in development.
  product_token: nil,
  steward_credentials: %{}
