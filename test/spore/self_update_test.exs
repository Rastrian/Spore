defmodule Spore.SelfUpdateTest do
  use ExUnit.Case, async: false

  alias Spore.SelfUpdate

  # Every test builds its own artifacts under a unique tmp dir; nothing here
  # touches the network, /opt or systemd (run/1 side effects live behind the
  # pure helpers tested below).
  setup do
    on_exit(fn ->
      Application.delete_env(:spore, :service_name)
      System.delete_env("SPORE_SECRET")
    end)

    :ok
  end

  describe "parse_flags/1" do
    test "defaults" do
      assert {:ok,
              %{
                check: false,
                version: nil,
                repo: "Rastrian/Spore",
                restart: false,
                install_root: "/opt",
                service: "spore-server"
              }} = SelfUpdate.parse_flags([])
    end

    test "every flag overrides its default" do
      assert {:ok, opts} =
               SelfUpdate.parse_flags([
                 "--check",
                 "--version",
                 "v0.2.8",
                 "--repo",
                 "someone/spore",
                 "--restart",
                 "--install-root",
                 "/tmp/spore-root"
               ])

      assert opts.check == true
      assert opts.version == "v0.2.8"
      assert opts.repo == "someone/spore"
      assert opts.restart == true
      assert opts.install_root == "/tmp/spore-root"
    end

    test "an unknown flag returns {:error, {:unknown_flag, _}}" do
      assert {:error, {:unknown_flag, "--bogus"}} = SelfUpdate.parse_flags(["--bogus"])
      assert {:error, {:unknown_flag, "--nope"}} = SelfUpdate.parse_flags(["--check", "--nope"])
    end

    test "the service name default comes from the application env" do
      Application.put_env(:spore, :service_name, "spore-prod")
      assert {:ok, %{service: "spore-prod"}} = SelfUpdate.parse_flags([])
    end
  end

  describe "compare_versions/2" do
    test "same version is :up_to_date, with or without the v prefix" do
      assert SelfUpdate.compare_versions("0.2.7", "v0.2.7") == :up_to_date
      assert SelfUpdate.compare_versions("v0.2.7", "0.2.7") == :up_to_date
      assert SelfUpdate.compare_versions("1.0.0", "1.0.0") == :up_to_date
    end

    test "a newer target is :update_available" do
      assert SelfUpdate.compare_versions("0.2.7", "v0.2.8") == :update_available
      assert SelfUpdate.compare_versions("0.2.7", "0.3.0") == :update_available
      assert SelfUpdate.compare_versions("0.9.9", "v1.0.0") == :update_available
    end

    test "components compare numerically, not lexicographically" do
      assert SelfUpdate.compare_versions("0.2.7", "v0.2.10") == :update_available
      assert SelfUpdate.compare_versions("0.2.10", "v0.2.9") == :newer_than_latest
      assert SelfUpdate.compare_versions("0.10.0", "v0.9.9") == :newer_than_latest
    end

    test "current newer than latest is :newer_than_latest" do
      assert SelfUpdate.compare_versions("0.2.9", "v0.2.8") == :newer_than_latest
      assert SelfUpdate.compare_versions("1.2.3", "1.2.2") == :newer_than_latest
    end
  end

  describe "asset_for_arch/1" do
    test "x86_64 and amd64 map to the x86_64 tarball" do
      assert SelfUpdate.asset_for_arch("x86_64") == {:ok, "spore-linux-x86_64.tar.gz"}
      assert SelfUpdate.asset_for_arch("amd64") == {:ok, "spore-linux-x86_64.tar.gz"}
    end

    test "aarch64 and arm64 map to the aarch64 tarball" do
      assert SelfUpdate.asset_for_arch("aarch64") == {:ok, "spore-linux-aarch64.tar.gz"}
      assert SelfUpdate.asset_for_arch("arm64") == {:ok, "spore-linux-aarch64.tar.gz"}
    end

    test "anything else is unsupported" do
      assert SelfUpdate.asset_for_arch("mips") == {:error, :unsupported_platform}
      assert SelfUpdate.asset_for_arch("") == {:error, :unsupported_platform}
    end
  end

  describe "verify_bundle!/2" do
    test "accepts a bundle whose embedded version matches the tag" do
      tarball = build_bundle("0.2.8")
      assert SelfUpdate.verify_bundle!(tarball, "v0.2.8") == :ok
      assert SelfUpdate.verify_bundle!(tarball, "0.2.8") == :ok
    end

    test "rejects a bundle bundled from a different version" do
      tarball = build_bundle("0.2.7")
      assert SelfUpdate.verify_bundle!(tarball, "v0.2.8") == {:error, :bundle_version_mismatch}
    end

    test "rejects a bundle without the spore/bin/spore launcher" do
      tarball = build_bundle("0.2.8", without_bin: true)
      assert SelfUpdate.verify_bundle!(tarball, "v0.2.8") == {:error, :bundle_version_mismatch}
    end

    test "rejects a non-gzip file as corrupt" do
      path = Path.join(new_tmp_dir!(), "not-a-tarball.tar.gz")
      File.write!(path, "this is definitely not a gzip stream\n")
      assert SelfUpdate.verify_bundle!(path, "v0.2.8") == {:error, :corrupt_tarball}
    end
  end

  describe "install_bundle!/3" do
    test "installs under --install-root and flips the spore symlink" do
      root = new_tmp_dir!()
      tarball = build_bundle("0.2.8")

      assert {:ok, dir} = SelfUpdate.install_bundle!(tarball, "v0.2.8", root)
      assert dir == Path.join(root, "spore-0.2.8")
      assert File.dir?(Path.join(dir, "lib/spore-0.2.8/ebin"))
      assert {:ok, target} = :file.read_link(Path.join(root, "spore"))
      assert to_string(target) == Path.absname(dir)

      # No staging symlink left behind.
      assert File.ls!(root) |> Enum.reject(&(&1 == "spore")) == ["spore-0.2.8"]
    end

    test "a second update flips the symlink again, keeping the old release" do
      root = new_tmp_dir!()

      assert {:ok, first} = SelfUpdate.install_bundle!(build_bundle("0.2.8"), "v0.2.8", root)
      assert {:ok, second} = SelfUpdate.install_bundle!(build_bundle("0.2.9"), "v0.2.9", root)

      assert {:ok, target} = :file.read_link(Path.join(root, "spore"))
      assert to_string(target) == Path.absname(second)
      assert target != Path.absname(first)

      # The previous release dir stays for rollback.
      assert File.dir?(Path.join(first, "lib/spore-0.2.8/ebin"))
      assert File.dir?(Path.join(second, "lib/spore-0.2.9/ebin"))
    end

    test "a corrupt tarball fails and leaves no directory behind" do
      root = new_tmp_dir!()
      path = Path.join(new_tmp_dir!(), "corrupt.tar.gz")
      File.write!(path, "garbage")

      assert {:error, {:tar_extract_failed, _}} = SelfUpdate.install_bundle!(path, "v0.2.9", root)
      refute File.exists?(Path.join(root, "spore-0.2.9"))
      refute File.exists?(Path.join(root, "spore"))
    end

    test "a bundle whose ebin dir does not match the tag is rejected" do
      root = new_tmp_dir!()
      tarball = build_bundle("0.2.8")

      assert {:error, {:missing_ebin, "0.2.9"}} =
               SelfUpdate.install_bundle!(tarball, "v0.2.9", root)

      refute File.exists?(Path.join(root, "spore-0.2.9"))
    end
  end

  # ------------------------------------------------------------- helpers ---

  defp new_tmp_dir! do
    dir = Path.join(System.tmp_dir!(), "spore-self-update-test-#{unique()}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)
    dir
  end

  defp unique do
    :crypto.strong_rand_bytes(6) |> Base.encode16(case: :lower)
  end

  # Build a real (tiny) release tarball on the fly with the same layout the
  # CI bundles ship: spore/bin/spore + spore/lib/spore-<version>/ebin.
  defp build_bundle(version, opts \\ []) do
    staging = Path.join(new_tmp_dir!(), "staging")
    File.mkdir_p!(Path.join(staging, "spore/lib/spore-#{version}/ebin"))
    File.mkdir_p!(Path.join(staging, "spore/bin"))
    File.write!(Path.join(staging, "spore/lib/spore-#{version}/ebin/spore.app"), "ok")

    unless opts[:without_bin] do
      File.write!(Path.join(staging, "spore/bin/spore"), "#!/bin/sh\nexit 0\n")
    end

    tarball = Path.join(new_tmp_dir!(), "spore-#{version}.tar.gz")
    {_, 0} = System.shell("tar czf #{shq(tarball)} -C #{shq(staging)} spore")
    tarball
  end

  defp shq(value), do: "'" <> String.replace(value, "'", "'\\''") <> "'"
end
