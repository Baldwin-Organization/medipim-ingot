# parity_harness.exs — run the whole-product parity harness over a cohort (gr-yfh).
#
#   mix run parity_harness.exs <cohort_dir> [report.json]
#
# `<cohort_dir>` holds one pair per product: `<stem>.json` (the contract-C HistoryEnvelope) and
# `<stem>.snapshot.json` (the snapshot medipim's ProductDeltaApplier materialized for it). See
# lib/ingest/parity.ex for the export contract and what each divergence class means.
#
# Prints the human summary, optionally writes the machine report, and EXITS NON-ZERO when any
# product diverges — this is the cutover gate (gr-be3 closes the gaps until it exits zero, or the
# residue is explained). The committed cohort under test/ingest/fixtures is a self-comparison
# against engine-produced baselines, so it exits 1 on the survivorship ties; that is honest, not a
# harness bug.

case System.argv() do
  [dir | rest] ->
    report = ParityHarness.from_dir(dir)
    IO.puts(ParityHarness.to_summary(report))

    with [out] <- rest do
      File.write!(out, ParityHarness.to_json(report))
      IO.puts("\nwrote #{out}")
    end

    if report.cohort.diverging > 0, do: System.halt(1)

  _ ->
    IO.puts(:stderr, "usage: mix run parity_harness.exs <cohort_dir> [report.json]")
    System.halt(2)
end
