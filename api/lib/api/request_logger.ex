defmodule Api.RequestLogger do
  @moduledoc false

  def init(opts), do: Plug.Logger.init(opts)

  def call(%Plug.Conn{request_path: path} = conn, _opts) when path in ["/health", "/ready"],
    do: conn

  def call(conn, opts), do: Plug.Logger.call(conn, opts)
end
