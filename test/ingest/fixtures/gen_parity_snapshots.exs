# test/ingest/fixtures/gen_parity_snapshots.exs — regenerate the committed parity baselines (gr-yfh).
#
#   mix run test/ingest/fixtures/gen_parity_snapshots.exs
#
# Writes `<stem>.snapshot.json` for each committed envelope: the engine's materialized snapshot in
# the parity wire shape (see lib/ingest/parity.ex). They are `"produced_by": "engine"`, so the
# harness treats them as a SELF-COMPARISON — a regression guard on the fold and the executable
# example of the export contract medipim must fill for the at-scale cohort. They are NOT applier
# output, and running the harness against them proves nothing about parity.
#
# Fixture tooling, like gen.exs beside it — it must run via `mix run` so lib/ is compiled.

for stem <- ~w(medipim_be_422156 medipim_fr_347025) do
  envelope = HistoryEnvelope.load!(Path.join(__DIR__, stem <> ".json"))
  encoded = JSON.encode!(ParityHarness.snapshot([envelope]))
  out = Path.join(__DIR__, stem <> ".snapshot.json")

  File.write!(out, encoded)
  IO.puts("wrote #{out} (#{byte_size(encoded)} bytes)")
end
