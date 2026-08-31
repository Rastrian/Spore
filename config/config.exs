import Config

config :logger, level: :info

# Allow overriding the control port via env var SPORE_CONTROL_PORT
spore_control_port =
  case System.get_env("SPORE_CONTROL_PORT") do
    nil -> 7835
    str -> String.to_integer(str)
  end

config :spore, control_port: spore_control_port

# The version is NOT configured here: mix.exs exposes it as the :spore
# application env (single source of truth is the @version attribute in
# mix.exs). Runtime code reads Application.get_env(:spore, :version); the
# escript boot path (application not started) falls back to the .app vsn.
