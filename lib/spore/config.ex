defmodule Spore.Config do
  @moduledoc false

  def apply_map(map) when is_map(map) do
    put(:control_port, map["control_port"])
    put(:tls, truthy(map["tls"]))
    put(:cacertfile, map["cacertfile"])
    put(:client_certfile, map["client_certfile"])
    put(:client_keyfile, map["client_keyfile"])
    put(:certfile, map["certfile"])
    put(:keyfile, map["keyfile"])
    put(:allow, map["allow"] && Spore.ACL.parse_list(map["allow"]))
    put(:deny, map["deny"] && Spore.ACL.parse_list(map["deny"]))
    put(:max_conns_per_ip, map["max_conns_per_ip"])
    put(:max_pending, map["max_pending"])
    put(:metrics_port, map["metrics_port"])
    put(:sndbuf, map["sndbuf"])
    put(:recbuf, map["recbuf"])
  end

  def reload_from_env do
    case Application.get_env(:spore, :config_path) do
      nil -> {:error, :no_config}
      path -> load_file(path)
    end
  end

  def load_file(path) do
    with {:ok, content} <- File.read(path),
         {:ok, map} <- Jason.decode(content) do
      apply_map(map)
      {:ok, :reloaded}
    else
      err -> err
    end
  end

  defp truthy(v), do: v in [true, 1, "1", "true", "TRUE"]
  defp put(_k, nil), do: :ok
  defp put(k, v), do: Application.put_env(:spore, k, v)
end
