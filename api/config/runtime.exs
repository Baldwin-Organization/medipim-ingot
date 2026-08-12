import Config

if config_env() == :prod do
  database_url =
    System.get_env("DATABASE_URL") ||
      raise "DATABASE_URL is required, e.g. postgres://user:pass@host:5432/golden_record_api"

  uri = URI.parse(database_url)
  [username, password] = uri.userinfo |> String.split(":", parts: 2)

  source_priority =
    case System.get_env("SOURCE_PRIORITY_JSON") do
      nil -> nil
      json -> JSON.decode!(json)
    end

  steward_credentials =
    System.fetch_env!("STEWARD_CREDENTIALS_JSON")
    |> JSON.decode!()
    |> Map.new(fn {principal, credential} ->
      {principal,
       %{
         bearer: List.wrap(credential["bearer"]),
         password: credential["password"]
       }}
    end)

  product_token = System.fetch_env!("PRODUCT_API_TOKEN")
  csrf_secret = System.fetch_env!("CSRF_SECRET")

  if byte_size(product_token) < 32,
    do: raise("PRODUCT_API_TOKEN must be at least 32 bytes")

  if byte_size(csrf_secret) < 32,
    do: raise("CSRF_SECRET must be at least 32 bytes")

  if map_size(steward_credentials) < 2,
    do: raise("STEWARD_CREDENTIALS_JSON must define at least two individual principals")

  steward_tokens =
    Enum.flat_map(steward_credentials, fn {principal, credential} ->
      if not is_binary(credential.password) or byte_size(credential.password) < 16,
        do: raise("steward #{principal} password must be at least 16 bytes")

      if credential.bearer == [],
        do: raise("steward #{principal} must have at least one bearer token")

      Enum.each(credential.bearer, fn token ->
        if not is_binary(token) or byte_size(token) < 24,
          do: raise("steward #{principal} bearer tokens must be at least 24 bytes")
      end)

      credential.bearer
    end)

  if length(steward_tokens) != length(Enum.uniq(steward_tokens)),
    do: raise("steward bearer tokens must be unique per principal")

  steward_passwords = steward_credentials |> Map.values() |> Enum.map(& &1.password)

  if length(steward_passwords) != length(Enum.uniq(steward_passwords)),
    do: raise("steward passwords must be unique per principal")

  if product_token in steward_tokens,
    do: raise("PRODUCT_API_TOKEN must not match a steward bearer token")

  config :golden_record_api,
    db: [
      hostname: uri.host,
      port: uri.port || 5432,
      username: username,
      password: password,
      database: String.trim_leading(uri.path || "/golden_record_api", "/")
    ],
    port: String.to_integer(System.get_env("PORT", "4000")),
    steward_port:
      System.get_env("STEWARD_PORT") && String.to_integer(System.get_env("STEWARD_PORT")),
    product_token: product_token,
    csrf_secret: csrf_secret,
    steward_credentials: steward_credentials,
    max_claims: String.to_integer(System.get_env("MAX_CLAIMS_PER_BATCH", "10000")),
    max_envelopes: String.to_integer(System.get_env("MAX_ENVELOPES_PER_BATCH", "1000")),
    source_priority: source_priority
end
