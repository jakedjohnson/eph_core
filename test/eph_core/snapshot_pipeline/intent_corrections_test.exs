defmodule EphCore.SnapshotPipeline.IntentCorrectionsTest do
  use ExUnit.Case, async: true

  alias EphCore.SnapshotPipeline.Intent

  @base_params %{utc: ~U[2026-07-07 10:54:38Z], targets: [:neptune]}

  describe "default corrections" do
    test "includes all three correction flags defaulting to false" do
      {:ok, snapshot} = Intent.new(@base_params)
      corrections = snapshot.intent.corrections

      assert corrections == %{precession_nutation: false, aberration: false, light_time: false}
    end

    test "aberration defaults to false when not specified" do
      {:ok, snapshot} = Intent.new(@base_params)
      assert snapshot.intent.corrections.aberration == false
    end

    test "light_time defaults to false when not specified" do
      {:ok, snapshot} = Intent.new(@base_params)
      assert snapshot.intent.corrections.light_time == false
    end
  end

  describe "corrections normalization" do
    test "passing aberration: true and light_time: true normalizes correctly" do
      params = Map.put(@base_params, :corrections, %{aberration: true, light_time: true})
      {:ok, snapshot} = Intent.new(params)
      corrections = snapshot.intent.corrections

      assert corrections.aberration == true
      assert corrections.light_time == true
      assert corrections.precession_nutation == false
    end

    test "partial corrections map gets missing keys defaulted to false" do
      params = Map.put(@base_params, :corrections, %{aberration: true})
      {:ok, snapshot} = Intent.new(params)
      corrections = snapshot.intent.corrections

      assert corrections.aberration == true
      assert corrections.light_time == false
      assert corrections.precession_nutation == false
    end

    test "existing precession_nutation key is preserved" do
      params = Map.put(@base_params, :corrections, %{precession_nutation: true, light_time: true})
      {:ok, snapshot} = Intent.new(params)
      corrections = snapshot.intent.corrections

      assert corrections.precession_nutation == true
      assert corrections.light_time == true
      assert corrections.aberration == false
    end
  end

  describe "corrections validation" do
    test "aberration: 'yes' fails validation with a clear error" do
      params = Map.put(@base_params, :corrections, %{aberration: "yes"})
      {:error, changeset} = Intent.new(params)

      messages = error_messages_for(changeset, :corrections)
      assert Enum.any?(messages, &String.contains?(&1, "aberration"))
    end

    test "light_time: 1 fails validation" do
      params = Map.put(@base_params, :corrections, %{light_time: 1})
      {:error, changeset} = Intent.new(params)

      messages = error_messages_for(changeset, :corrections)
      assert Enum.any?(messages, &String.contains?(&1, "light_time"))
    end

    test "precession_nutation: 'true' fails validation" do
      params = Map.put(@base_params, :corrections, %{precession_nutation: "true"})
      {:error, changeset} = Intent.new(params)

      messages = error_messages_for(changeset, :corrections)
      assert Enum.any?(messages, &String.contains?(&1, "precession_nutation"))
    end
  end

  describe "apparent_geocentric?/1" do
    test "returns false when both flags are false (default)" do
      {:ok, snapshot} = Intent.new(@base_params)
      assert Intent.apparent_geocentric?(snapshot.intent) == false
    end

    test "returns false when only aberration is true" do
      params = Map.put(@base_params, :corrections, %{aberration: true, light_time: false})
      {:ok, snapshot} = Intent.new(params)
      assert Intent.apparent_geocentric?(snapshot.intent) == false
    end

    test "returns false when only light_time is true" do
      params = Map.put(@base_params, :corrections, %{aberration: false, light_time: true})
      {:ok, snapshot} = Intent.new(params)
      assert Intent.apparent_geocentric?(snapshot.intent) == false
    end

    test "returns true when both aberration and light_time are true" do
      params = Map.put(@base_params, :corrections, %{aberration: true, light_time: true})
      {:ok, snapshot} = Intent.new(params)
      assert Intent.apparent_geocentric?(snapshot.intent) == true
    end
  end

  # Ecto changeset errors are {message, opts} tuples; extract just the string.
  defp error_messages_for(changeset, field) do
    changeset.errors
    |> Keyword.get_values(field)
    |> Enum.map(fn {msg, _opts} -> msg end)
  end
end
