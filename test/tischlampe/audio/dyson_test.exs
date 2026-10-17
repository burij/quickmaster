defmodule Tischlampe.Audio.DysonTest do
  use ExUnit.Case, async: true

  alias Tischlampe.Audio.Dyson

  @dir Path.join([__DIR__, "..", "..", "fixtures", "dyson"])
  @sr 44_100.0

  defp read_f32(path) do
    for <<f::float-little-32 <- File.read!(path)>>, do: f
  end

  defp assert_matches(name, params) do
    input = read_f32(Path.join(@dir, "stress_in.f32"))
    expected = read_f32(Path.join(@dir, "#{name}_out.f32"))
    {actual, _} = Dyson.process(Dyson.new(@sr, params), input)

    max_diff =
      Enum.zip(actual, expected)
      |> Enum.map(fn {a, b} -> abs(a - b) end)
      |> Enum.max()

    # The native plugin computes in float32, this port in double; the
    # residual is < -70 dBFS.
    assert max_diff < 5.0e-4, "#{name}: max sample diff #{max_diff}"
  end

  test "matches the native plugin with stress parameters" do
    assert_matches("stress", %{peak_limit: -6.0, release_time: 0.5, cfrate: 0.5, crate: 0.5})
  end

  test "matches the native plugin with default parameters" do
    assert_matches("default", %{peak_limit: 0.0, release_time: 0.0, cfrate: 0.5, crate: 0.5})
  end

  test "hard-limits output to +/- MAXLEVEL" do
    input = read_f32(Path.join(@dir, "stress_in.f32"))

    params = %{peak_limit: 0.0, release_time: 0.0, cfrate: 0.5, crate: 0.5}
    {out, _} = Dyson.process(Dyson.new(@sr, params), input)

    assert Enum.max(Enum.map(out, &abs/1)) <= 0.9 + 1.0e-6
  end

  test "is stateless between fresh instances" do
    input = read_f32(Path.join(@dir, "stress_in.f32")) |> Enum.take(5_000)
    params = %{peak_limit: -6.0, release_time: 0.5, cfrate: 0.5, crate: 0.5}

    {a, _} = Dyson.process(Dyson.new(@sr, params), input)
    {b, _} = Dyson.process(Dyson.new(@sr, params), input)

    assert a == b
  end
end
