defmodule GoldenRecord.MixProject do
  use Mix.Project

  # A deliberately dependency-free prototype: pure functions, stdlib only (the built-in JSON
  # module in Elixir 1.18+ is why no Jason dependency is needed). Modules are flat for now
  # (Codes, Substrate, Cluster, HistoryEnvelope, ClaimMapping, …); namespacing under
  # GoldenRecord.* is a future follow-up.
  def project do
    [
      app: :golden_record,
      version: "0.2.0",
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      deps: [],
      test_coverage: [summary: [threshold: 0]],
      # the fixture generator lives next to the fixtures it produces; it is not a test
      test_ignore_filters: [~r"/fixtures/"]
    ]
  end

  def application do
    [extra_applications: [:logger, :crypto]]
  end
end
