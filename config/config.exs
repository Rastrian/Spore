import Config

config :logger, level: :info

# Allow overriding the control port via env var SPORE_CONTROL_PORT
spore_control_port =
  case System.get_env("SPORE_CONTROL_PORT") do
    nil -> 7835
    str -> String.to_integer(str)
  end

config :spore, control_port: spore_control_port

# Baked at compile time so `spore update` (and any runtime code) can report
# the version the binary was built from without touching mix tooling.
config :spore, version: "0.2.7"
