# Chicago-style court: no mocks, real files on disk.
#
# Verifies every docs/case-studies/*.md case study:
#   1. Each number token inside a "Quantified outcome" block appears
#      verbatim in the source artifact(s) the case study cites
#      (bench/BASELINES-CANONICAL.md, bench/fleet/*.json,
#      docs/demonstration.md, or any other repo-relative artifact).
#   2. Anti-vacuity mutation: corrupting one number on a temp copy of the
#      md makes this court refuse the case study.
#
# A cited source artifact missing on disk FAILS the case study (fail-loud).

defmodule AshPplan.CaseStudyNumbersCourt do
  @moduledoc false

  @repo_root Path.expand("../..", __DIR__)
  @receipts_dir Path.join([Path.expand("../..", __DIR__), "docs/case-studies/receipts"])

  @doc """
  Court over raw md text. Returns {:ok, :conformant}, {:ok, :no_quantified_block}
  (nothing to check), or {:error, reasons}. Reason `:not_plan_run_first` marks a
  study whose numbers are not backed by an executed P-Plan run receipt.
  """
  def run(md_text) do
    cond do
      # A template is not a case study; `<<placeholder>>` markers skip it.
      template?(md_text) ->
        {:ok, :template}

      true ->
        do_run(md_text)
    end
  end

  defp template?(md), do: Regex.match?(~r/<<[^>]+>>/, md)

  defp do_run(md_text) do
    blocks = quantified_blocks(md_text)

    cond do
      blocks == [] ->
        {:ok, :no_quantified_block}

      true ->
        cited = cited_sources(md_text, @repo_root)
        tokens = Enum.flat_map(blocks, fn {_, b} -> number_tokens(b) end) |> Enum.uniq()

        receipt_error =
          case run_receipt_for(md_text, tokens) do
            {:ok, _path} -> []
            :no_receipts_dir -> [":not_plan_run_first — no docs/case-studies/receipts/ dir"]
            :no_cited_receipt ->
              [":not_plan_run_first — Quantified-outcome block cites no run receipt " <>
                 "(docs/case-studies/receipts/*.json); hand-written baseline-only studies are refused"]
            {:error, :no_executed_json_receipt} ->
              [":not_plan_run_first — the cited run receipt is missing, not JSON, or contains " <>
                 "none of this study's cited numbers #{inspect(Enum.take(tokens, 8))}"]
          end

        reasons =
          if cited == [] do
            ["no cited source artifacts found"]
          else
            for {rel, false, _abs} <- cited do
              "cited source artifact missing on disk: #{rel}"
            end ++
              for {_line, block} <- blocks,
                  token <- number_tokens(block),
                  not verbatim?(token, cited) do
                "number #{inspect(token)} not found verbatim in any cited source"
              end
          end

        reasons = reasons ++ reproduction_errors(md_text) ++ receipt_error

        if reasons == [], do: {:ok, :conformant}, else: {:error, reasons}
    end
  end

  @doc """
  Run-first check: every study's Reproduction section must name an executed-run
  command (`mix run examples/...` or `mix test ...`).
  """
  def reproduction_errors(md) do
    case section(md, "Reproduction") do
      nil ->
        [":not_plan_run_first — no Reproduction section"]

      text ->
        unless Regex.match?(~r/mix (run|test)\b[^\n]*\b(examples|test)\//, text) do
          [":not_plan_run_first — Reproduction section names no executed-run command " <>
             "(mix run examples/... or mix test ...)"]
        else
          []
        end
    end
  end

  @doc """
  Run-first check: the study's Quantified-outcome block must be backed by a
  cited receipt artifact that exists on disk, carries execution provenance,
  and contains at least one of the study's numbers. Two lawful receipt forms:
    - an executed P-Plan run receipt: docs/case-studies/receipts/*.json
      (JSON with executed_at/final_status/replay_commands/exit keys), or
    - a witnessed receipt: receipts/*.md|log (repo receipts/ dir) carrying an
      executed `mix run|test` command plus observed result.
  Full number coverage is enforced by the verbatim-in-cited-source check,
  since the receipt path itself is a cited source. Returns
  {:ok, path} | :no_receipts_dir | :no_cited_receipt | {:error, :no_executed_json_receipt}.
  """
  def run_receipt_for(md, tokens) do
    cited = cited_receipts(md)

    cond do
      cited == [] ->
        :no_cited_receipt

      true ->
        case File.ls(@receipts_dir) do
          {:error, _} ->
            :no_receipts_dir

          {:ok, _files} ->
            Enum.find_value(cited, {:error, :no_executed_json_receipt}, fn rel ->
              abs = Path.join(@repo_root, rel)

              if File.exists?(abs) do
                content = File.read!(abs)

                if executed_run?(content) and Enum.any?(tokens, &String.contains?(content, &1)) do
                  {:ok, abs}
                end
              end
            end)
        end
    end
  end

  @doc "Receipt artifacts the md cites: docs/case-studies/receipts/*.json and repo receipts/*.{md,log,txt}."
  def cited_receipts(md) do
    Regex.scan(~r{(?<![\w/.])((?:docs/case-studies/)?receipts/[\w\-./]+\.(?:json|md|log|txt))}, md)
    |> Enum.map(&hd/1)
    |> Enum.uniq()
  end

  defp executed_run?(content) do
    # Machine-generated JSON run receipts carry execution provenance keys from
    # the executed P-Plan run; static hand-written JSON would not. Witnessed
    # md/log receipts carry an executed mix command plus its observed result.
    Regex.match?(~r/"(executed_at|final_status|replay_commands|exit)"/, content) or
      (Regex.match?(~r/mix (run|test)\b/, content) and
         Regex.match?(~r/\d+ tests?, 0 failures|Finished in \d/, content))
  end

  @doc false
  # Section extraction that is fence-aware: `^#+\s` heading detection ignores
  # lines inside ``` or ~~~ code fences, so fenced shell comments (`# run ...`)
  # no longer truncate a section. Returns the section body, or nil.
  defp section(md, name) do
    with_section(md, ~r/^#+\s.*#{name}/i, fn pairs, i ->
      pairs
      |> Enum.drop(i + 1)
      |> Enum.take_while(fn {l, top} -> not (top and Regex.match?(~r/^#+\s/, l)) end)
      |> Enum.map(&elem(&1, 0))
      |> Enum.join("\n")
    end)
  end

  defp with_section(md, heading_re, fun) do
    lines = String.split(md, ["\r\n", "\n"])
    flags = outside_fence_flags(lines)
    pairs = Enum.zip(lines, flags)

    case Enum.find_index(pairs, fn {l, top} -> top and Regex.match?(heading_re, l) end) do
      nil -> nil
      i -> fun.(pairs, i)
    end
  end

  # Boolean per line: true when the line sits outside any ``` / ~~~ fence.
  # The fence marker line itself is never top-level.
  defp outside_fence_flags(lines) do
    {flags, _} =
      Enum.map_reduce(lines, false, fn line, in_fence ->
        if Regex.match?(~r/\A(```|~~~)/, line) do
          {false, not in_fence}
        else
          {not in_fence, in_fence}
        end
      end)

    flags
  end

  @doc "Split md into blocks following each /quantified/i heading until the next heading (fence-aware)."
  def quantified_blocks(md) do
    lines = String.split(md, ["\r\n", "\n"])
    flags = outside_fence_flags(lines)
    pairs = Enum.zip(lines, flags)

    pairs
    |> Enum.with_index()
    |> Enum.flat_map(fn {{line, top}, i} ->
      if top and Regex.match?(~r/^#+.*quantified/i, line) do
        body =
          pairs
          |> Enum.drop(i + 1)
          |> Enum.take_while(fn {l, top?} -> not (top? and Regex.match?(~r/^#+\s/, l)) end)
          |> Enum.map(&elem(&1, 0))
          |> Enum.join("\n")

        [{i + 1, body}]
      else
        []
      end
    end)
  end

  @doc "Repo-relative artifact paths cited in the md. Missing files are kept (fail-loud)."
  def cited_sources(md, repo_root) do
    # Relative cites resolve against the repo root AND any `cd <dir>` context
    # named in the Reproduction section (cross-repo reproduction is lawful).
    cd_dirs =
      Regex.scan(~r{cd\s+(/[\w\-./]+)}, md)
      |> Enum.map(fn [_, d] -> d end)
      |> Enum.uniq()

    roots = [repo_root | cd_dirs]

    Regex.scan(~r{(?<![\w/.])((?:bench|docs|priv|test|receipts)/[\w\-./]+\.(?:md|json|txt|exs|ex|ttl|log))}, md)
    |> Enum.map(fn [_, rel] -> {rel, Enum.map(roots, &Path.join(&1, rel))} end)
    |> Enum.uniq_by(fn {rel, _} -> rel end)
    |> Enum.map(fn {rel, candidates} -> {rel, Enum.any?(candidates, &File.exists?/1), candidates} end)
  end

  @doc """
  Number tokens in a block, skipping tokens embedded in dates (YYYY-MM-DD,
  optionally with an ISO time suffix), compact timestamps
  (YYYYMMDDTHHMMSSZ), and hex hashes/digests (16+ hex chars — the required
  a-f letter stops pure-decimal numbers being swallowed as "hashes").
  """
  def number_tokens(block) do
    cleaned =
      block
      |> String.replace(~r/\d{4}-\d{2}-\d{2}(?:T\d{2}:\d{2}(?::\d{2})?Z?)?/, " ")
      |> String.replace(~r/\b\d{8}T\d{6}Z\b/, " ")
      |> String.replace(~r/\b(?=[0-9a-f]{16,}\b)(?=[0-9a-f]*[a-f])[0-9a-f]{16,}\b/i, " ")

    Regex.scan(~r/\d+(?:\.\d+)?/, cleaned)
    |> Enum.map(&hd/1)
    |> Enum.uniq()
  end

  defp verbatim?(token, cited) do
    Enum.any?(cited, fn {_rel, exists?, candidates} ->
      exists? and
        Enum.any?(candidates, fn abs ->
          File.exists?(abs) and String.contains?(File.read!(abs), token)
        end)
    end)
  end
end

defmodule CaseStudyNumbersTest do
  use ExUnit.Case, async: true

  @repo_root Path.expand("../..", __DIR__)
  @case_dir Path.join(@repo_root, "docs/case-studies")

  defp case_files do
    case File.ls(@case_dir) do
      {:ok, files} ->
        files |> Enum.filter(&String.ends_with?(&1, ".md")) |> Enum.sort()

      {:error, _} ->
        []
    end
  end

  test "case-study directory exists with at least one case study" do
    assert File.dir?(@case_dir), "docs/case-studies/ missing"
    files = case_files()
    assert files != [], "no *.md case studies in docs/case-studies/"
  end

  test "every number token in a Quantified-outcome block is verbatim in a cited source artifact" do
    files = case_files()
    assert files != []

    # Anti-vacuity of the court itself: the directory must actually contain
    # at least one checked Quantified-outcome block, otherwise this court
    # would pass while checking nothing.
    checked =
      Enum.count(files, fn file ->
        md = File.read!(Path.join(@case_dir, file))
        AshPplan.CaseStudyNumbersCourt.quantified_blocks(md) != []
      end)

    assert checked >= 1,
           "no *.md in docs/case-studies/ has a Quantified-outcome block; court is vacuous"

    failures =
      files
      |> Enum.map(fn file ->
        {file, AshPplan.CaseStudyNumbersCourt.run(File.read!(Path.join(@case_dir, file)))}
      end)
      |> Enum.filter(fn {_file, verdict} -> match?({:error, _}, verdict) end)

    message =
      Enum.map_join(failures, "\n", fn {f, {:error, rs}} ->
        "#{f}:\n" <> Enum.map_join(rs, "\n", &("  - " <> &1))
      end)

    assert failures == [], "court refusals:\n#{message}"
  end

  test "anti-vacuity: corrupting one number in a temp copy makes the court refuse" do
    files =
      case_files()
      |> Enum.filter(fn file ->
        match?({:ok, :conformant}, AshPplan.CaseStudyNumbersCourt.run(File.read!(Path.join(@case_dir, file))))
      end)

    assert files != [], "no conformant case study to mutate"

    for file <- files do
      md = File.read!(Path.join(@case_dir, file))

      blocks = AshPplan.CaseStudyNumbersCourt.quantified_blocks(md)
      tokens = Enum.flat_map(blocks, fn {_, b} -> AshPplan.CaseStudyNumbersCourt.number_tokens(b) end)
      assert tokens != [], "#{file}: no number tokens to mutate"

      target = hd(tokens)
      # Mutate EVERY occurrence of the token to a sentinel that cannot appear
      # verbatim in any source artifact, so the mutation cannot accidentally
      # stay conformant via a duplicate of the same token elsewhere.
      mutated = String.replace(md, target, "999777333")

      assert mutated != md, "#{file}: mutation of #{inspect(target)} was a no-op"

      assert {:error, reasons} = AshPplan.CaseStudyNumbersCourt.run(mutated),
             "#{file}: court admitted a corrupted case study (mutated #{inspect(target)})"

      assert Enum.any?(reasons, &String.contains?(&1, "not found verbatim")),
             "#{file}: refusal did not name the verbatim check: #{inspect(reasons)}"
    end
  end
end
