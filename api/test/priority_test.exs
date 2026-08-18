alias GoldenRecord.{Priority}

defmodule Api.PriorityTest do
  use ExUnit.Case, async: false

  setup do
    old = Application.get_env(:golden_record_api, :source_priority)

    on_exit(fn ->
      if old == nil do
        Application.delete_env(:golden_record_api, :source_priority)
      else
        Application.put_env(:golden_record_api, :source_priority, old)
      end
    end)

    :ok
  end

  test "defaults to no source ranking" do
    Application.delete_env(:golden_record_api, :source_priority)

    priority = Api.Priority.current()

    assert Priority.rank(priority, "name", "manufacturer") == :infinity
    assert Priority.rank(priority, "name", "supplier") == :infinity
  end

  test "reads per-field and default source tiers from config" do
    Application.put_env(:golden_record_api, :source_priority, %{
      "fields" => %{"name" => [["manufacturer"], ["supplier"]]},
      "default" => [["supplier"], ["marketplace"]]
    })

    priority = Api.Priority.current()

    assert Priority.rank(priority, "name", "manufacturer") == 0
    assert Priority.rank(priority, "name", "supplier") == 1
    assert Priority.rank(priority, "color", "supplier") == 0
    assert Priority.rank(priority, "color", "marketplace") == 1
  end
end
