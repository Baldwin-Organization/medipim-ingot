defmodule Api.Auth do
  @moduledoc """
  Authentication for the product and steward surfaces.

  Product writes use their own bearer token. Steward access uses individual credentials: either
  a bearer token mapped to a principal or HTTP Basic with that principal's username and password.
  The authenticated principal, never a request-body name, is recorded on decisions.

  Empty credentials disable auth for local development only; production runtime configuration
  requires both product and steward credentials.
  """
  import Plug.Conn

  def init(surface) when surface in [:product, :steward], do: surface

  def call(conn, surface) do
    case authenticate(get_req_header(conn, "authorization"), surface) do
      {:ok, principal, scheme} ->
        conn
        |> assign(:"#{surface}_principal", principal)
        |> assign(:auth_scheme, scheme)

      :disabled ->
        conn
        |> assign(:"#{surface}_principal", "development")
        |> assign(:auth_scheme, :disabled)

      :error ->
        conn
        |> challenge(surface)
        |> put_resp_content_type("application/json")
        |> send_resp(401, JSON.encode!(%{error: "unauthorized"}))
        |> halt()
    end
  end

  def authenticate(headers, :product) do
    expected = Application.fetch_env!(:golden_record_api, :product_token)

    cond do
      expected == nil ->
        :disabled

      match?(["Bearer " <> _], headers) and secure_bearer?(headers, expected) ->
        {:ok, "product", :bearer}

      true ->
        :error
    end
  end

  def authenticate(headers, :steward) do
    credentials = steward_credentials()

    cond do
      credentials == %{} ->
        :disabled

      match?(["Bearer " <> _], headers) ->
        ["Bearer " <> token] = headers
        bearer_principal(credentials, token)

      match?(["Basic " <> _], headers) ->
        ["Basic " <> encoded] = headers
        basic_principal(credentials, encoded)

      true ->
        :error
    end
  end

  def csrf_token(principal) do
    secret = Application.get_env(:golden_record_api, :csrf_secret, "development-csrf-secret")

    :crypto.mac(:hmac, :sha256, secret, "steward:#{principal}")
    |> Base.url_encode64(padding: false)
  end

  def valid_csrf?(principal, token) when is_binary(token),
    do: Plug.Crypto.secure_compare(csrf_token(principal), token)

  def valid_csrf?(_principal, _token), do: false

  defp secure_bearer?(["Bearer " <> token], expected),
    do: byte_size(token) == byte_size(expected) and Plug.Crypto.secure_compare(token, expected)

  defp steward_credentials do
    Application.get_env(:golden_record_api, :steward_credentials, %{})
  end

  defp bearer_principal(credentials, token) do
    Enum.find_value(credentials, :error, fn {principal, credential} ->
      tokens = Map.get(credential, :bearer, Map.get(credential, "bearer", [])) |> List.wrap()

      if Enum.any?(
           tokens,
           &(byte_size(&1) == byte_size(token) and Plug.Crypto.secure_compare(&1, token))
         ),
         do: {:ok, to_string(principal), :bearer}
    end)
  end

  defp basic_principal(credentials, encoded) do
    with {:ok, userinfo} <- Base.decode64(encoded),
         [user, password] <- String.split(userinfo, ":", parts: 2),
         credential when not is_nil(credential) <-
           Enum.find_value(credentials, fn {principal, credential} ->
             if to_string(principal) == user, do: credential
           end),
         expected when is_binary(expected) <-
           Map.get(credential, :password, Map.get(credential, "password")),
         true <- byte_size(password) == byte_size(expected),
         true <- Plug.Crypto.secure_compare(password, expected) do
      {:ok, user, :basic}
    else
      _ -> :error
    end
  end

  defp challenge(conn, :steward),
    do: put_resp_header(conn, "www-authenticate", ~s(Basic realm="steward"))

  defp challenge(conn, _), do: conn
end
