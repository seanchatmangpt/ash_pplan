defmodule AshPPlan.PackageHygieneTest do
  @moduledoc """
  Guards Hex package file selection hygiene in `mix.exs`.

  Hex copies directory entries recursively without honoring downstream
  rejections, so filtered trees (`planning/`, `docs/`, `lib/`, `priv/`) must
  expand to leaf file paths only, excluding archived planning artifacts while
  preserving every active planning specification.
  """

  use ExUnit.Case, async: true

  @root Path.expand("..", __DIR__)

  describe "planning/ package hygiene" do
    test "excludes planning/archive/ and directory entries while preserving active planning files" do
      files = AshPPlan.MixProject.project()[:package][:files]
      file_set = MapSet.new(files)

      archived_on_disk =
        @root
        |> Path.join("planning/archive/**")
        |> Path.wildcard()
        |> Enum.reject(&File.dir?/1)
        |> Enum.map(&Path.relative_to(&1, @root))
        |> Enum.sort()

      # Anti-vacuity: the archive directory must actually hold files on disk so
      # the exclusion predicate is witnessed against real inputs.
      assert archived_on_disk != []

      for archived <- archived_on_disk do
        refute MapSet.member?(file_set, archived),
               "archived planning file #{archived} leaked into package files"
      end

      refute Enum.any?(
               files,
               &(&1 == "planning/archive" or String.starts_with?(&1, "planning/archive/"))
             )

      # Directory entries under planning/ would let Hex recurse wholesale and
      # re-import planning/archive/.
      for path <- files, path == "planning" or String.starts_with?(path, "planning/") do
        refute File.dir?(Path.join(@root, path)),
               "directory entry #{path} in package files would bypass Hex exclusions"
      end

      active_on_disk =
        @root
        |> Path.join("planning/**")
        |> Path.wildcard()
        |> Enum.reject(&File.dir?/1)
        |> Enum.map(&Path.relative_to(&1, @root))
        |> Enum.reject(
          &(&1 == "planning/archive" or String.starts_with?(&1, "planning/archive/"))
        )
        |> Enum.sort()

      assert active_on_disk != []

      for active <- active_on_disk do
        assert MapSet.member?(file_set, active),
               "active planning file #{active} is missing from package files"
      end
    end
  end
end
