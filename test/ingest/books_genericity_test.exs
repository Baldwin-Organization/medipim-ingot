# The genericity gate, engine-side (gr-vgb): BOOK records — ISBN-10/ISBN-13 from two overlapping
# sources — migrate with ZERO engine changes. Everything book-specific is config + adapter:
# CodeRegistry isbn data rows, the Isbn module (10 → 13 canonicalization, checksums), the
# BooksAdapter mapping, and fixtures. lib/golden_record_core.ex must be byte-identical to the
# base branch (`git diff origin/main...HEAD -- lib/golden_record_core.ex` is the gate).
# The API-level loop (dry-run → cutover → reads) lives in api/test/books_e2e_test.exs;
# this suite proves the same claims resolve correctly in the bare engine.

alias GoldenRecord.{Events, Substrate, Priority, Cluster, Stewardship}

defmodule BooksGenericityTest do
  use ExUnit.Case, async: true

  @fixtures Path.expand("fixtures/books", __DIR__)
  @priority Priority.new(%{}, [])

  @tide {:isbn13, "9781861972712"}
  @lichens1 {:isbn13, "9780198526636"}
  @lichens2 {:isbn13, "9780198526643"}
  @moth10 {:isbn13, "9780571199983"}
  @moth979 {:isbn13, "9791090636071"}

  # ── the Isbn scheme module: checksums + 10 → 13 equivalence ──────────────────
  describe "Isbn" do
    test "a checksum-valid ISBN-10 converts to its 978 ISBN-13 (the equivalence family)" do
      assert Isbn.to_isbn13("1-86197-271-7") == {:ok, "9781861972712"}
      assert Isbn.to_isbn13("978-1-86197-271-2") == {:ok, "9781861972712"}
      assert Isbn.code("1861972717") == {:ok, "isbn13:9781861972712"}
    end

    test "the X check digit (mod-11 value 10) is accepted, case-insensitively" do
      # 097522980 → mod-11 check digit 10 = X
      assert Isbn.valid?("0-9752298-0-X")
      assert Isbn.to_isbn13("097522980x") == {:ok, "9780975229804"}
    end

    test "checksum failures and non-Bookland 13s are rejected, with reasons" do
      assert {:error, reason10} = Isbn.to_isbn13("1-86197-271-8")
      assert reason10 =~ "mod-11"

      assert {:error, reason13} = Isbn.to_isbn13("978-1-86197-271-9")
      assert reason13 =~ "mod-10"

      assert {:error, bookland} = Isbn.to_isbn13("5012345678900")
      assert bookland =~ "978 or 979"

      assert {:error, shape} = Isbn.to_isbn13("not-an-isbn")
      assert shape =~ "not ISBN-shaped"
    end

    test "a 979 title has no ISBN-10 form — the 13 is its only spelling" do
      assert Isbn.to_isbn13("979-10-90636-07-1") == {:ok, "9791090636071"}
    end
  end

  # ── the scheme registry: declaration file ↔ live data rows agree ─────────────
  test "the books scheme declaration (contract registry format) matches CodeRegistry's data rows" do
    declaration =
      @fixtures |> Path.join("scheme_registry.json") |> File.read!() |> JSON.decode!()

    assert declaration["schema_version"] == "1"
    names = Enum.map(declaration["schemes"], & &1["name"])
    assert Enum.sort(names) == ["isbn10", "isbn13"]

    for scheme <- declaration["schemes"] do
      atom = CodeRegistry.engine_scheme(scheme["name"])
      assert is_atom(atom), "#{scheme["name"]} must be a registered engine scheme"
      assert scheme["class"] == "identity"
      assert CodeRegistry.classification(scheme["name"]) == :identity
      assert scheme["bridge_grade"] == "national"
      assert CodeRegistry.bridge_grade(atom) == :national
    end
  end

  test "isbn13 is a KNOWN scheme on the wire — the validator raises no unknown-scheme advisory" do
    batch = claims()
    assert {:ok, []} = ClaimsValidator.validate(batch)
  end

  # ── the engine run: same pipeline, new vertical, zero engine changes ─────────
  test "the 10/13 pair resolves to ONE golden record; contradiction, collision, and merge are governed" do
    batch = claims()
    {:ok, engine_claims} = CanonicalClaims.to_engine(batch, recorded_at: ~D[2026-06-10])
    stamped = engine_claims |> Enum.with_index(1) |> Enum.map(fn {c, i} -> %{c | order: i} end)

    live = Substrate.current(stamped)
    clusters = Cluster.variants(live)

    # equivalence: librex's "1-86197-271-7" and bookwire's "978-1-86197-271-2" are ONE cluster
    # holding ONE code; the four books cluster into exactly four identities.
    assert MapSet.new([@tide]) in clusters
    assert length(clusters) == 4

    %{events: events, ledger: ledger} = FinerClaims.fold_forward(stamped, MapSet.new())
    assert Enum.count(events, &match?(%Events.IdentityMinted{}, &1)) == 4

    key_of = fn code -> Enum.find_value(ledger.members, fn {k, c} -> code in c && k end) end
    tide_key = key_of.(@tide)

    # the bridged listings share one key end-to-end
    assert key_of.(@lichens1) == key_of.(@lichens2)

    # contradiction surfaced PER DIMENSION: only pages disagrees on the Tide Atlas — both
    # sources' candidates are on the flag; the agreeing title raises nothing.
    conflicts = Stewardship.detect(ledger.members, live, @priority, ~D[2026-06-10])
    assert [%Events.ConflictFlagged{subject: {:attr, ^tide_key, "pages"}, candidates: cands}] = conflicts
    assert Enum.sort(cands) == [{"bookwire", 256}, {"librex", 240}]

    # code collision: BW-9003 spans both librex editions, so ONE variant's grouping claims
    # point at TWO legacy products — flagged for a steward, not silently picked.
    lichens_key = key_of.(@lichens1)

    assert [%Events.ConflictFlagged{subject: {:collision, ^lichens_key}, candidates: prods}] =
             Stewardship.detect_collisions(ledger.members, live, ~D[2026-06-10])

    assert prods |> Enum.map(& &1.product) |> Enum.sort() == [1002, 1003]

    # convergence: replaying the same truth at a later date changes NOTHING
    assert %{events: []} = FinerClaims.fold_forward(stamped, MapSet.new(), ledger, [~D[2026-06-15]])

    # the merge candidate: bookwire's correction bridges two ESTABLISHED records (Moth Hours
    # hardcover ↔ the 979 collected edition) — the over-merge guard proposes, never fuses.
    update = BooksAdapter.bookwire_claims(Path.join(@fixtures, "bookwire_feed_update.json"))
    {:ok, update_claims} = CanonicalClaims.to_engine(update, recorded_at: ~D[2026-06-20])

    next = length(stamped) + 1
    all = stamped ++ (update_claims |> Enum.with_index(next) |> Enum.map(fn {c, i} -> %{c | order: i} end))

    %{events: bridge_events, ledger: after_bridge} =
      FinerClaims.fold_forward(all, MapSet.new(), ledger, [~D[2026-06-20]])

    moth_keys = Enum.sort([key_of.(@moth10), key_of.(@moth979)])

    assert [%Events.ConflictFlagged{subject: {:merge, ^moth_keys}}] =
             Enum.filter(bridge_events, &match?(%Events.ConflictFlagged{subject: {:merge, _}}, &1))

    refute Enum.any?(bridge_events, &match?(%Events.IdentitiesMerged{}, &1))
    assert after_bridge.members == ledger.members
  end

  defp claims do
    BooksAdapter.claims(
      Path.join(@fixtures, "librex_catalog.json"),
      Path.join(@fixtures, "bookwire_feed.json")
    )
  end
end
