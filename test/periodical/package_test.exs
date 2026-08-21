defmodule Periodical.PackageTest do
  use ExUnit.Case, async: true

  test "the declared release files exclude verification and generated assets" do
    package_files = Mix.Project.config() |> Keyword.fetch!(:package) |> Keyword.fetch!(:files)

    refute Enum.any?(package_files, &String.starts_with?(&1, "test"))
    refute Enum.any?(package_files, &String.starts_with?(&1, "integration"))
    refute Enum.any?(package_files, &String.starts_with?(&1, "config"))
    refute Enum.any?(package_files, &String.starts_with?(&1, "doc"))
    refute Enum.any?(package_files, &String.contains?(&1, "MIGRATION"))
  end
end
