defmodule AlpacaExTest do
  use ExUnit.Case
  doctest AlpacaEx

  test "version returns a string" do
    assert is_binary(AlpacaEx.version())
  end
end
