defmodule Spore.SelfUpdate do
  @moduledoc """
  In-place self-update for a server install on the VPS, where the release
  layout is:

      /opt/spore-0.2.8                     bundled release (tarball root "spore/")
      /opt/spore -> /opt/spore-0.2.8       symlink flipped atomically on update
      /etc/systemd/system/spore-server.service
        ExecStart=/opt/spore/bin/spore start   (Restart=on-failure)

  Each step is verified before the next one: the tarball is checked with
  `gzip -t` and `tar tzf` (the bundled `spore/lib/spore-<version>/` must match
  the tag — a tag released without bumping mix.exs once shipped a
  wrong-version bundle), the extracted dir must contain
  `lib/spore-<version>/ebin` on disk, and only then is the `/opt/spore`
  symlink replaced via `mv -Tf` (atomic; `ln -sfn` is not).

  ## The release-mode escape hatch

  In the `mix release` daemon `bin/spore` needs a release command; it cannot
  run the CLI directly. `spore update` is therefore invoked through the
  release `eval` command, which runs the code in a fresh node where the
  application is NOT booted yet (no baked config, no Logger). The CLI handles
  that by calling `Application.ensure_all_started(:spore)` itself before
  updating. The exact command used on the VPS is:

      SPORE_UPDATE_ARGS="--check" /opt/spore/bin/spore eval \
        'Spore.CLI.main(["update" | OptionParser.split(System.get_env("SPORE_UPDATE_ARGS") || "")])'

  All examples must be self-contained: network access (GitHub API + release
  download) and root (writing under /opt, systemctl) are only needed for the
  real install; `--check` needs neither download nor write access.
  """

  require Logger

  @default_repo "Rastrian/Spore"
  @default_install_root "/opt"
  @default_service "spore-server"

  @tag_re ~r/^v\d/

  # System.shell/2 has no timeout option, so the wall-clock limits live in
  # curl itself (--max-time); gzip/tar/uname are local and fast.
  @api_max_time 25
  @download_max_time 240
  @restart_poll_ms 500
  @restart_wait_ms 10_000

  @update_switches [
    check: :boolean,
    version: :string,
    repo: :string,
    restart: :boolean,
    install_root: :string
  ]

  # ---------------------------------------------------------------- flags ---

  @doc """
  Parse the argv of a `spore update` invocation (without the leading
  "update"). Returns the effective update options; an unrecognized flag aborts
  with `{:error, {:unknown_flag, flag}}`.
  """
  @spec parse_flags([String.t()]) ::
          {:ok,
           %{
             check: boolean(),
             version: String.t() | nil,
             repo: String.t(),
             restart: boolean(),
             install_root: String.t(),
             service: String.t()
           }}
          | {:error, {:unknown_flag, String.t()}}
  def parse_flags(args) when is_list(args) do
    case OptionParser.parse(args, strict: @update_switches) do
      {opts, _positional, []} ->
        {:ok,
         %{
           check: Keyword.get(opts, :check, false),
           version: Keyword.get(opts, :version),
           repo: Keyword.get(opts, :repo, @default_repo),
           restart: Keyword.get(opts, :restart, false),
           install_root: Keyword.get(opts, :install_root, @default_install_root),
           service: Application.get_env(:spore, :service_name, @default_service)
         }}

      {_opts, _positional, [{flag, _} | _]} ->
        {:error, {:unknown_flag, flag}}
    end
  end

  # --------------------------------------------------------------- compare ---

  @doc """
  Compare the running `current` version against `target` (both may carry a
  leading "v"). Components are compared numerically, so 0.2.10 > 0.2.9.

  Returns:

    * `:up_to_date`         - both are the same version
    * `:update_available`   - target is newer than current
    * `:newer_than_latest`  - current is newer than target
  """
  @spec compare_versions(String.t(), String.t()) ::
          :up_to_date | :update_available | :newer_than_latest
  def compare_versions(current, target) do
    cur = parse_version(current)
    tgt = parse_version(target)

    cond do
      cur == tgt -> :up_to_date
      cur < tgt -> :update_available
      true -> :newer_than_latest
    end
  end

  defp parse_version(version) do
    version
    |> String.trim_leading("v")
    |> String.split(".")
    |> Enum.map(&version_component/1)
  end

  defp version_component(part) do
    case Integer.parse(part) do
      {int, rest} -> {int, rest}
      :error -> {0, part}
    end
  end

  # -------------------------------------------------------------- platform ---

  @doc """
  Map the output of `uname -m` to the release asset name for this host.
  """
  @spec asset_for_arch(String.t()) :: {:ok, String.t()} | {:error, :unsupported_platform}
  def asset_for_arch(arch) when arch in ["x86_64", "amd64"],
    do: {:ok, "spore-linux-x86_64.tar.gz"}

  def asset_for_arch(arch) when arch in ["aarch64", "arm64"],
    do: {:ok, "spore-linux-aarch64.tar.gz"}

  def asset_for_arch(_other), do: {:error, :unsupported_platform}

  # ------------------------------------------------------------- the update ---

  @doc """
  Run `spore update` with the argv following the "update" command. Every step
  is verified before the next one; any failure short-circuits with
  `{:error, reason}` and leaves the current install (and its symlink) intact.
  """
  @spec run([String.t()]) :: :ok | {:error, term()}
  def run(flags) when is_list(flags) do
    with {:ok, opts} <- parse_flags(flags),
         {:ok, current} <- current_version(),
         current = String.trim_leading(current, "v"),
         {:ok, target} <- resolve_target(opts),
         target = String.trim_leading(target, "v") do
      Logger.info("current #{current}")

      if opts.version,
        do: Logger.info("target #{target} (pinned with --version)"),
        else: Logger.info("latest #{target}")

      case compare_versions(current, target) do
        :up_to_date ->
          Logger.info("already up to date (#{current})")
          :ok

        :newer_than_latest when is_nil(opts.version) ->
          Logger.info("#{current} is newer than latest #{target}, nothing to do")
          :ok

        comparison when comparison == :update_available or not is_nil(opts.version) ->
          # An explicit --version may also downgrade, that is on purpose.
          if comparison == :newer_than_latest,
            do: Logger.info("downgrading to #{target} as requested by --version")

          if opts.check do
            Logger.info(
              "update available: #{current} -> #{target} (--check only, not installing)"
            )

            :ok
          else
            install(opts, target)
          end
      end
    end
  end

  defp current_version do
    version =
      case Application.get_env(:spore, :version) do
        nil ->
          case Application.spec(:spore, :vsn) do
            nil -> nil
            vsn -> to_string(vsn)
          end

        baked ->
          to_string(baked)
      end

    if version, do: {:ok, version}, else: {:error, :no_current_version}
  end

  defp resolve_target(opts) do
    if version = opts.version, do: {:ok, version}, else: latest_tag(opts.repo)
  end

  defp latest_tag(repo) do
    url = "https://api.github.com/repos/#{repo}/tags?per_page=100"

    case sh("curl -fsSL --max-time #{@api_max_time} #{shq(url)}") do
      {body, 0} ->
        case Jason.decode(body) do
          {:ok, tags} when is_list(tags) ->
            case Enum.find_value(tags, &tag_name/1) do
              nil -> {:error, :no_release_tag}
              tag -> {:ok, tag}
            end

          _other ->
            {:error, :bad_tags_response}
        end

      {_out, status} ->
        {:error, {:curl_failed, status}}
    end
  end

  defp tag_name(%{"name" => name}) when is_binary(name),
    do: if(name =~ @tag_re, do: name, else: nil)

  defp tag_name(_other), do: nil

  defp install(opts, target) do
    with {:ok, asset} <- arch_asset(),
         {:ok, url} <- release_asset_url(opts.repo, "v" <> target, asset) do
      tarball = temp_tarball(target)
      Logger.info("downloading #{url}")

      try do
        with :ok <- download(url, tarball),
             :ok <- verify_bundle!(tarball, target),
             {:ok, dir} <- install_bundle!(tarball, target, opts.install_root) do
          Logger.info("installed #{dir}")
          Logger.info("symlink flipped")

          if opts.restart, do: restart_service(opts.service), else: :ok
        end
      after
        # The tarball must never outlive the update attempt, success or not.
        File.rm_rf(tarball)
      end
    end
  end

  defp arch_asset do
    case sh("uname -m") do
      {arch, 0} -> asset_for_arch(String.trim(arch))
      {_out, status} -> {:error, {:uname_failed, status}}
    end
  end

  defp release_asset_url(repo, tag, asset_name) do
    url = "https://api.github.com/repos/#{repo}/releases/tags/#{tag}"

    case sh("curl -fsSL --max-time #{@api_max_time} #{shq(url)}") do
      {body, 0} ->
        case Jason.decode(body) do
          {:ok, %{"assets" => assets}} when is_list(assets) ->
            case Enum.find(assets, &(&1["name"] == asset_name)) do
              %{"browser_download_url" => dl} when is_binary(dl) -> {:ok, dl}
              _other -> {:error, {:asset_not_found, asset_name}}
            end

          _other ->
            {:error, :bad_release_response}
        end

      {_out, status} ->
        {:error, {:curl_failed, status}}
    end
  end

  defp download(url, dest) do
    case sh("curl -fsSL --max-time #{@download_max_time} #{shq(url)} -o #{shq(dest)}") do
      {_out, 0} -> :ok
      {_out, status} -> {:error, {:curl_failed, status}}
    end
  end

  # ------------------------------------------------------ bundle integrity ---

  @doc """
  Verify a downloaded tarball before anything is installed: it must be a valid
  gzip stream and its listing must contain `spore/bin/spore` plus
  `spore/lib/spore-<version>/`, where `<version>` is `tag` without the leading
  "v". A bundle whose embedded version does not match the tag yields
  `{:error, :bundle_version_mismatch}` and nothing gets installed.
  """
  @spec verify_bundle!(Path.t(), String.t()) ::
          :ok | {:error, :corrupt_tarball | :bundle_version_mismatch}
  def verify_bundle!(tarball, tag) do
    version = String.trim_leading(tag, "v")

    with {:ok, entries} <- tar_listing(tarball),
         :ok <- require_entry(entries, "spore/bin/spore"),
         :ok <- require_entry(entries, "spore/lib/spore-#{version}") do
      :ok
    end
  end

  defp tar_listing(tarball) do
    with {_out, 0} <- sh("gzip -t #{shq(tarball)}"),
         {out, 0} <- sh("tar tzf #{shq(tarball)}") do
      entries =
        out
        |> String.split("\n", trim: true)
        |> Enum.map(fn line -> line |> String.trim_leading("./") |> String.trim_trailing("/") end)
        |> MapSet.new()

      {:ok, entries}
    else
      {_out, _status} -> {:error, :corrupt_tarball}
    end
  end

  defp require_entry(entries, entry) do
    if MapSet.member?(entries, entry), do: :ok, else: {:error, :bundle_version_mismatch}
  end

  # ---------------------------------------------------------------- install ---

  @doc """
  Install the (verified) `tarball` of `tag` under `install_root`, then flip the
  `<install_root>/spore` symlink to the new release directory atomically.
  Returns `{:ok, dir}` with the absolute install dir. On failure the partial
  directory is removed and the current symlink is left untouched.
  """
  @spec install_bundle!(Path.t(), String.t(), Path.t()) :: {:ok, Path.t()} | {:error, term()}
  def install_bundle!(tarball, tag, install_root) do
    version = String.trim_leading(tag, "v")
    dir = Path.join(install_root, "spore-#{version}")

    with :ok <- File.mkdir_p(dir),
         # The bundle root is a top-level "spore/" dir; strip it so the
         # tarball's spore/bin/spore lands at <dir>/bin/spore like the running
         # install (/opt/spore-<version>/bin/spore).
         {_out, 0} <- sh("tar xzf #{shq(tarball)} --strip-components=1 -C #{shq(dir)}"),
         :ok <- verify_ebin(dir, version),
         :ok <- flip_symlink(install_root, dir) do
      {:ok, dir}
    else
      {:error, reason} ->
        # Never leave a half-extracted release behind.
        File.rm_rf(dir)
        {:error, reason}

      {_out, status} ->
        File.rm_rf(dir)
        {:error, {:tar_extract_failed, status}}
    end
  end

  defp verify_ebin(dir, version) do
    if File.dir?(Path.join(dir, Path.join("lib/spore-#{version}", "ebin"))),
      do: :ok,
      else: {:error, {:missing_ebin, version}}
  end

  defp flip_symlink(install_root, new_dir) do
    rand = :crypto.strong_rand_bytes(4) |> Base.encode16(case: :lower)
    staging = Path.join(install_root, ".spore-symlink-#{rand}")
    link = Path.join(install_root, "spore")

    with :ok <- File.ln_s(Path.absname(new_dir), staging),
         {_out, 0} <- sh("mv -Tf #{shq(staging)} #{shq(link)}") do
      :ok
    else
      failed ->
        File.rm(staging)
        {:error, failed}
    end
  end

  # --------------------------------------------------------------- restart ---

  defp restart_service(service) do
    Logger.info("restarting service #{service}")

    case sh("systemctl restart #{shq(service)}") do
      {_out, 0} ->
        wait_for_active(service, div(@restart_wait_ms, @restart_poll_ms))

      {_out, status} ->
        {:error, {:restart_failed, status}}
    end
  end

  defp wait_for_active(service, 0 = _attempts_left),
    do: {:error, {:service_not_active, service}}

  defp wait_for_active(service, attempts_left) do
    case sh("systemctl is-active --quiet #{shq(service)}") do
      {_out, 0} ->
        Logger.info("service restarted")
        :ok

      _other ->
        Process.sleep(@restart_poll_ms)
        wait_for_active(service, attempts_left - 1)
    end
  end

  # ----------------------------------------------------------------- utils ---

  defp temp_tarball(version) do
    rand = :crypto.strong_rand_bytes(4) |> Base.encode16(case: :lower)
    Path.join(System.tmp_dir!(), "spore-update-#{version}-#{rand}.tar.gz")
  end

  defp sh(cmd, opts \\ []) when is_binary(cmd) do
    System.shell(cmd, opts)
  end

  # Single-quote a value for the POSIX shell; paths/URLs never contain quotes
  # but the flag values are user input.
  defp shq(value), do: "'" <> String.replace(value, "'", "'\\''") <> "'"
end
