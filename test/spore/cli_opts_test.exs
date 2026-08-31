defmodule Spore.CliOptsTest do
  use ExUnit.Case, async: false

  alias Spore.CLI

  @spore_env_keys [
    :control_port,
    :tls,
    :cacertfile,
    :client_certfile,
    :client_keyfile,
    :certfile,
    :keyfile,
    :allow,
    :deny,
    :max_conns_per_ip,
    :metrics_port,
    :sndbuf,
    :recbuf,
    :otel_enable,
    :otel_endpoint,
    :json_logs,
    :config_path,
    :ssl_verify
  ]

  setup do
    System.delete_env("SPORE_SECRET")

    on_exit(fn ->
      Enum.each(@spore_env_keys, &Application.delete_env(:spore, &1))
      System.delete_env("SPORE_SECRET")
    end)

    :ok
  end

  describe "apply_local_opts/1" do
    test "positional local port with all defaults" do
      assert CLI.apply_local_opts(["3000", "--to", "h"]) == %{
               local_port: 3000,
               local_host: "localhost",
               to: "h",
               port: 0,
               secret: nil
             }
    end

    test "--local-port wins over the positional port" do
      opts = CLI.apply_local_opts(["1111", "--to", "h", "--local-port", "2222"])
      assert opts.local_port == 2222
    end

    test "a missing local port raises ArgumentError" do
      assert_raise ArgumentError, ~r/missing local port/, fn ->
        CLI.apply_local_opts(["--to", "h"])
      end
    end

    test "--local-host and --port (plus its -p alias)" do
      opts =
        CLI.apply_local_opts(["3000", "--to", "h", "--local-host", "127.0.0.1", "--port", "5"])

      assert opts.local_host == "127.0.0.1"
      assert opts.port == 5
      assert CLI.apply_local_opts(["3000", "--to", "h", "-p", "7"]).port == 7
    end

    test "SPORE_SECRET env is picked up when --secret is absent" do
      System.put_env("SPORE_SECRET", "from-env")
      assert CLI.apply_local_opts(["3000", "--to", "h"]).secret == "from-env"
    end

    test "an explicit --secret wins over SPORE_SECRET" do
      System.put_env("SPORE_SECRET", "from-env")

      assert CLI.apply_local_opts(["3000", "--to", "h", "--secret", "from-flag"]).secret ==
               "from-flag"
    end

    test "--control-port, --tls and --insecure set the application env" do
      CLI.apply_local_opts(["3000", "--to", "h", "--control-port", "9999", "--tls", "--insecure"])

      assert Application.get_env(:spore, :control_port) == 9999
      assert Application.get_env(:spore, :tls) == true
      assert Application.get_env(:spore, :ssl_verify) == false
    end

    test "no flags are applied to the env by default" do
      CLI.apply_local_opts(["3000", "--to", "h"])

      Enum.each(@spore_env_keys, fn key ->
        assert Application.get_env(:spore, key) == nil
      end)
    end
  end

  describe "apply_server_opts/1" do
    test "defaults without arguments" do
      assert CLI.apply_server_opts([]) == [
               min_port: 1024,
               max_port: 65535,
               secret: nil,
               bind_addr: "0.0.0.0",
               bind_tunnels: nil
             ]
    end

    test "SPORE_SECRET env is used when --secret is absent" do
      System.put_env("SPORE_SECRET", "from-env")
      assert CLI.apply_server_opts([])[:secret] == "from-env"
    end

    test "every server option overrides its default" do
      opts =
        CLI.apply_server_opts([
          "--min-port",
          "20000",
          "--max-port",
          "21000",
          "--secret",
          "s",
          "--bind-addr",
          "127.0.0.1",
          "--bind-tunnels",
          "1.2.3.4"
        ])

      assert opts == [
               min_port: 20000,
               max_port: 21000,
               secret: "s",
               bind_addr: "127.0.0.1",
               bind_tunnels: "1.2.3.4"
             ]
    end

    test "--allow stores the parsed ACL list in the application env" do
      CLI.apply_server_opts(["--allow", "10.0.0.0/8,1.2.3.4"])

      assert Application.get_env(:spore, :allow) == [
               {:cidr, {10, 0, 0, 0}, 8},
               {:ip, {1, 2, 3, 4}}
             ]
    end

    test "--deny stores the parsed ACL list in the application env" do
      CLI.apply_server_opts(["--deny", "9.9.9.9,192.168.0.0/16"])

      assert Application.get_env(:spore, :deny) == [
               {:ip, {9, 9, 9, 9}},
               {:cidr, {192, 168, 0, 0}, 16}
             ]
    end

    test "--max-conns-per-ip sets the application env" do
      CLI.apply_server_opts(["--max-conns-per-ip", "3"])
      assert Application.get_env(:spore, :max_conns_per_ip) == 3
    end
  end

  describe "server cap validation" do
    setup do
      on_exit(fn ->
        Application.delete_env(:spore, :max_conns_per_ip)
        Application.delete_env(:spore, :max_pending)
      end)

      :ok
    end

    test "validate_caps!/0 accepts unset, :infinity and positive values" do
      :ok = Spore.Server.validate_caps!()

      Application.put_env(:spore, :max_conns_per_ip, 50)
      Application.put_env(:spore, :max_pending, 100)
      assert Spore.Server.validate_caps!() == :ok

      Application.put_env(:spore, :max_conns_per_ip, :infinity)
      assert Spore.Server.validate_caps!() == :ok
    end

    test "validate_caps!/0 rejects a zero cap with a clear error" do
      Application.put_env(:spore, :max_conns_per_ip, 0)

      assert_raise ArgumentError, ~r/invalid :max_conns_per_ip value 0/, fn ->
        Spore.Server.validate_caps!()
      end
    end

    test "validate_caps!/0 rejects non-integer cap values" do
      Application.put_env(:spore, :max_pending, "20")

      assert_raise ArgumentError, ~r/invalid :max_pending value "20"/, fn ->
        Spore.Server.validate_caps!()
      end
    end
  end
end
