defmodule GoldenRecord.Uuid do
  @moduledoc """
  Engine-minted identity (gr-2a8): a record born without a source code — a steward-created
  description, an uploaded asset — gets a `{:uuid, v4}` identity code. The scheme is shared
  across lanes, so such a claim must carry an explicit `entity:` (see `Lanes.of_claim/1`).
  """

  def mint, do: {:uuid, v4()}

  def v4 do
    <<a::48, _::4, b::12, _::2, c::62>> = :crypto.strong_rand_bytes(16)
    <<u0::32, u1::16, u2::16, u3::16, u4::48>> = <<a::48, 4::4, b::12, 2::2, c::62>>

    :io_lib.format(~c"~8.16.0b-~4.16.0b-~4.16.0b-~4.16.0b-~12.16.0b", [u0, u1, u2, u3, u4])
    |> IO.iodata_to_binary()
  end
end
