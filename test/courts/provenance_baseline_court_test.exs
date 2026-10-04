# RA2 delta-plan court: codify today's green provenance baseline as a
# regression court. Read-only on the tree; real subprocess + file/JSON reads,
# no mocks (Chicago). Four checks:
#   1. priv/ggen/vendor/verify_lock.sh exits 0 with an "OK" verdict line.
#   2. PACKS.lock.json source_git_sha == marketplace HEAD, else typed
#      RE-PIN NEEDED failure.
#   3. Every provenance.ttl packOntologySha256 matches the sha256 of the file
#      its entry names (packName -> vendor/<name>/ontology.ttl,
#      overlayPath -> <overlayPath>/ontology.ttl, specimenRole entries
#      skipped, fail-closed on unrecognized shapes) -- parser semantics
#      mirrored from bin/gate's provenance_digest_verify python parser.
#   4. The receipt-chain head (tmp/mf/.ggen_igniter/receipts/.chain-head.json)
#      is strictly extended by the receipt store: every pinned receipt id is
#      still present with the same receipt_hash and the store only grows --
#      bin/gate's receipt-chain-verify drop-detection semantics.
# Anti-vacuity: tmp-copy mutations (flipped digest, unrecognized entry shape,
# dropped/rewritten chain head, moved marketplace HEAD) must fail the court's
# own predicates, and verify_lock.sh must fail closed against a pinless repo.
defmodule AshPplan.Courts.ProvenanceBaselineCourtTest do
  use ExUnit.Case, async: false

  @root File.cwd!()
  @verify_lock Path.join(@root, "priv/ggen/vendor/verify_lock.sh")
  @lock Path.join(@root, "priv/ggen/vendor/PACKS.lock.json")
  @prov Path.join(@root, "priv/ggen/vendor/provenance.ttl")
  @vendor Path.join(@root, "priv/ggen/vendor")
  @store Path.join(@root, "tmp/mf/.ggen_igniter/receipts")

  defp marketplace_dir,
    do: Path.expand(System.get_env("GGEN_MARKETPLACE_DIR") || "~/ggen-marketplace")

  defp tmp_dir, do: Path.join(@root, "tmp/ra2-court-#{System.unique_integer([:positive])}")

  # -- check 1: verify_lock.sh --------------------------------------------------

  test "verify_lock.sh exits 0 with an OK verdict on the green tree" do
    {out, 0} = System.cmd("bash", [@verify_lock], cd: @root)
    assert out =~ "verify_lock: OK"
  end

  test "verify_lock.sh fails closed against a marketplace missing the pin (anti-vacuity)" do
    tmp = tmp_dir()
    fake = Path.join(tmp, "fake-market")
    {_, 0} = System.cmd("git", ["init", "-q", fake])
    on_exit(fn -> File.rm_rf!(tmp) end)

    env = System.get_env() |> Map.put("GGEN_MARKETPLACE_DIR", fake) |> Enum.to_list()
    {out, code} = System.cmd("bash", [@verify_lock], cd: @root, env: env, stderr_to_stdout: true)

    assert code != 0
    assert out =~ "does not exist in"
  end

  # -- check 2: lock pin vs marketplace HEAD --------------------------------------

  test "lock source_git_sha equals marketplace HEAD (typed RE-PIN NEEDED on drift)" do
    assert pin_matches_head(marketplace_dir()) == :ok
    assert lock_pin() =~ ~r/^[0-9a-f]{40}$/
  end

  test "pin-vs-head drift reports the typed RE-PIN NEEDED message (anti-vacuity)" do
    pin = lock_pin()
    tmp = tmp_dir()
    repo = Path.join(tmp, "moved-market")
    {_, 0} = System.cmd("git", ["init", "-q", repo])
    File.write!(Path.join(repo, "f.txt"), "moved")
    {_, 0} = System.cmd("git", ["-C", repo, "add", "."])

    {_, 0} =
      System.cmd("git", [
        "-C",
        repo,
        "-c",
        "user.email=c@c",
        "-c",
        "user.name=c",
        "commit",
        "-qm",
        "moved"
      ])

    on_exit(fn -> File.rm_rf!(tmp) end)

    {:error, msg} = pin_matches_head(repo)
    assert msg =~ "RE-PIN NEEDED"
    assert msg =~ pin
    assert msg =~ "sync.sh"
  end

  # -- check 3: provenance.ttl digest court (mirrors bin/gate) ---------------------

  test "every provenance.ttl packOntologySha256 matches the file its entry names" do
    assert {:ok, checked, skipped} = provenance_digest_verify(@prov, @vendor)
    assert length(checked) >= 1
    # The specimen skip-list and the overlay-shaped entry must both be live.
    assert Enum.any?(skipped, &(&1 =~ "specimenRole"))
  end

  test "a flipped digest in a tmp provenance copy fails the predicate (anti-vacuity)" do
    prov_tmp = tmp_file("provenance.ttl")
    File.write!(prov_tmp, flip_first_digest(File.read!(@prov)))

    assert {:error, msg} = provenance_digest_verify(prov_tmp, @vendor)
    assert msg =~ "sha256"
  end

  test "an unrecognized entry shape fails closed (anti-vacuity)" do
    prov_tmp = tmp_file("provenance.ttl")

    File.write!(
      prov_tmp,
      String.trim_trailing(File.read!(@prov)) <>
        "\n\ntdbv:weird a prov:Entity ;\n    tdbv:packOntologySha256 \"#{String.duplicate("a", 64)}\" ;\n"
    )

    assert {:error, msg} = provenance_digest_verify(prov_tmp, @vendor)
    assert msg =~ "unrecognized entry shape"
  end

  # -- check 4: receipt-chain head strictly extended --------------------------------

  test "receipt store strictly extends the pinned chain head" do
    assert {:ok, n} = chain_extends_head(@store)
    assert n >= 1
  end

  test "dropping or re-hashing a pinned receipt fails the extension predicate (anti-vacuity)" do
    tmp = tmp_dir()
    store_tmp = Path.join(tmp, "receipts")
    File.mkdir_p!(store_tmp)
    on_exit(fn -> File.rm_rf!(tmp) end)

    copy_store(store_tmp)

    # (a) head file dropped entirely -> fail-closed.
    assert {:error, msg} = chain_extends_head(store_tmp)
    assert msg =~ "no .chain-head.json"

    # (b) head pins a receipt the store no longer contains -> drop detected.
    File.cp!(Path.join(@store, ".chain-head.json"), Path.join(store_tmp, ".chain-head.json"))
    File.rm!(Path.join(store_tmp, "2026-10-04.jsonl"))
    assert {:error, msg} = chain_extends_head(store_tmp)
    assert msg =~ "dropped"

    # (c) a pinned receipt re-hashed in the store -> tamper detected.
    File.cp!(Path.join(@store, "2026-10-04.jsonl"), Path.join(store_tmp, "2026-10-04.jsonl"))
    mutated = Path.join(store_tmp, "2026-10-04.jsonl")

    File.write!(
      mutated,
      String.replace(
        File.read!(mutated),
        ~s("receipt_hash":"sha256:),
        ~s("receipt_hash":"sha256:0),
        global: false
      )
    )

    assert {:error, msg} = chain_extends_head(store_tmp)
    assert msg =~ "re-hashed"
  end

  # -- helpers ---------------------------------------------------------------------

  defp lock_pin, do: @lock |> File.read!() |> Jason.decode!() |> Map.fetch!("source_git_sha")

  # The typed check-2 predicate: :ok while marketplace HEAD == pin, else
  # {:error, "RE-PIN NEEDED ..."} naming both shas and the recovery.
  defp pin_matches_head(market) do
    pin = lock_pin()

    case System.cmd("git", ["-C", market, "rev-parse", "HEAD"]) do
      {out, 0} ->
        head = String.trim(out)

        if head == pin do
          :ok
        else
          {:error,
           "RE-PIN NEEDED: PACKS.lock.json source_git_sha #{pin} != marketplace HEAD #{head} " <>
             "-- re-run priv/ggen/vendor/sync.sh to re-pin, then regenerate provenance.ttl"}
        end

      {err, code} ->
        {:error, "RE-PIN NEEDED: marketplace repo at #{market} unreadable (#{code}): #{err}"}
    end
  end

  defp tmp_file(name) do
    dir = tmp_dir()
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    Path.join(dir, name)
  end

  defp copy_store(dest) do
    Path.wildcard(Path.join(@store, "*.jsonl"))
    |> Enum.each(&File.cp!(&1, Path.join(dest, Path.basename(&1))))
  end

  defp flip_first_digest(text) do
    Regex.replace(
      ~r/tdbv:packOntologySha256 "([0-9a-f])/,
      text,
      fn _all, d ->
        flipped = if d == "0", do: "1", else: "0"
        ~s(tdbv:packOntologySha256 "#{flipped})
      end,
      global: false
    )
  end

  # Mirrors bin/gate's provenance_digest_verify parser, fail-closed on
  # unrecognized shapes. {:ok, checked_paths, skipped_descriptions} | {:error, msg}.
  defp provenance_digest_verify(prov, vendor) do
    text = File.read!(prov)
    block_re = ~r/^(tdbv:\S+)\s+a\s+prov:Entity\s*;(.*?)(?=^\S|\z)/sm

    blocks =
      Regex.scan(block_re, text, capture: :all_but_first)
      |> Enum.map(fn [subj, block] -> {subj, block, line_of(text, subj)} end)

    if blocks == [] do
      {:error, "provenance-verify: FAIL: no prov:Entity blocks parsed from #{prov}"}
    else
      {checked, skipped, bad, errors} =
        Enum.reduce(blocks, {[], [], [], []}, &check_block(vendor, &2, &1))

      cond do
        errors != [] ->
          {:error, "provenance-verify: FAIL: " <> hd(Enum.reverse(errors))}

        bad != [] ->
          {:error, "provenance-verify: FAIL: " <> hd(Enum.reverse(bad))}

        checked == [] ->
          {:error, "provenance-verify: FAIL: no verifiable entries in #{prov}"}

        true ->
          {:ok, Enum.reverse(checked), Enum.reverse(skipped)}
      end
    end
  end

  defp check_block(vendor, {checked, skipped, bad, errors}, {subj, block, ln}) do
    cond do
      (role = pred(block, "specimenRole")) != nil ->
        {checked, ["#{subj} (line #{ln}, specimenRole=#{role})" | skipped], bad, errors}

      true ->
        sha = pred(block, "packOntologySha256")
        overlay = pred(block, "overlayPath")
        name = pred(block, "packName")

        case resolve_path(vendor, sha, overlay, name) do
          {:ok, path} ->
            if File.exists?(path) do
              got =
                path
                |> File.read!()
                |> then(&:crypto.hash(:sha256, &1))
                |> Base.encode16(case: :lower)

              if got == sha,
                do: {[path | checked], skipped, bad, errors},
                else:
                  {checked, skipped, ["#{path}: sha256 #{got} != provenance #{sha}" | bad],
                   errors}
            else
              {checked, skipped, ["#{path}: missing (provenance records sha256 #{sha})" | bad],
               errors}
            end

          {:error, reason} ->
            {checked, skipped, bad,
             [
               "#{subj} (line #{ln}): unrecognized entry shape " <>
                 "(packName=#{inspect(name)} overlayPath=#{inspect(overlay)} " <>
                 "packOntologySha256=#{if(sha, do: "present", else: "absent")}) -- #{reason}"
               | errors
             ]}
        end
    end
  end

  defp resolve_path(vendor, sha, overlay, name) do
    cond do
      sha && overlay ->
        root = vendor |> Path.dirname() |> Path.dirname() |> Path.dirname()
        {:ok, Path.join([root, overlay, "ontology.ttl"])}

      sha && name && !overlay ->
        {:ok, Path.join([vendor, name, "ontology.ttl"])}

      true ->
        {:error, "extend the parser or declare the predicate out-of-scope"}
    end
  end

  defp line_of(text, subj) do
    case :binary.match(text, subj) do
      {pos, _} -> text |> binary_part(0, pos) |> String.split("\n") |> length()
      :nomatch -> 0
    end
  end

  defp pred(block, name) do
    case Regex.run(~r/tdbv:#{name}\s+"([^"]+)"/, block) do
      [_, v] -> v
      _ -> nil
    end
  end

  # Mirrors bin/gate's receipt-chain-verify drop-detection semantics, fail-closed
  # when the head is absent. {:ok, store_size} | {:error, msg}.
  defp chain_extends_head(store) do
    head_path = Path.join(store, ".chain-head.json")
    partitions = Path.wildcard(Path.join(store, "*.jsonl")) |> Enum.sort()

    cond do
      partitions == [] ->
        {:error, "no receipts under #{store}"}

      true ->
        seen =
          Enum.reduce(partitions, %{}, fn part, acc ->
            part
            |> File.read!()
            |> String.split("\n")
            |> Enum.reject(&(&1 == ""))
            |> Enum.reduce(acc, fn line, acc ->
              case Jason.decode(line) do
                {:ok, %{"id" => id, "receipt_hash" => hash}}
                when is_binary(id) and is_binary(hash) ->
                  Map.put(acc, id, hash)

                {:ok, _} ->
                  throw({:break, "#{Path.basename(part)}: receipt missing id or receipt_hash"})

                {:error, _} ->
                  throw({:break, "#{Path.basename(part)}: unparseable line"})
              end
            end)
          end)

        cond do
          not File.exists?(head_path) ->
            {:error, "no .chain-head.json pinned under #{store} (fail-closed)"}

          true ->
            old = head_path |> File.read!() |> Jason.decode!() |> Map.get("receipts") || %{}

            missing = old |> Map.keys() |> Enum.reject(&Map.has_key?(seen, &1))

            changed =
              old
              |> Enum.filter(fn {rid, h} -> Map.get(seen, rid) != h end)
              |> Enum.map(&elem(&1, 0))

            cond do
              missing != [] ->
                {:error,
                 "store does not extend pinned head: #{length(missing)} receipt(s) dropped"}

              changed != [] ->
                {:error,
                 "store does not extend pinned head: #{length(changed)} receipt(s) re-hashed (tampered)"}

              map_size(seen) < map_size(old) ->
                {:error,
                 "store does not extend pinned head: store shrank #{map_size(old)} -> #{map_size(seen)}"}

              true ->
                {:ok, map_size(seen)}
            end
        end
    end
  catch
    {:break, msg} -> {:error, msg}
  end
end
