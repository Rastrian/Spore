defmodule Spore.Tracing do
  @moduledoc false

  def start do
    if Application.get_env(:spore, :otel_enable, false) and loaded_exporter?() do
      endpoint = Application.get_env(:spore, :otel_endpoint, "http://localhost:4318")
      headers = Application.get_env(:spore, :otel_headers, %{})
      exporter_opts = %{protocol: :http_protobuf, endpoint: endpoint, headers: headers}
      _ = :application.ensure_all_started(:opentelemetry)
      _ = :application.ensure_all_started(:opentelemetry_exporter)
      _ = apply(:opentelemetry_exporter, :setup, [[exporter: {:otlp, exporter_opts}]])
      :ok
    else
      :ok
    end
  end

  def with_span(name, attrs \\ %{}, fun) when is_function(fun, 0) do
    if loaded?() do
      OpenTelemetry.Tracer.with_span(name, fn ->
        set_attrs(attrs)
        fun.()
      end)
    else
      fun.()
    end
  end

  def add_event(name, attrs \\ %{}) do
    if loaded?() do
      OpenTelemetry.Tracer.add_event(name, attrs)
    else
      :ok
    end
  end

  def set_attrs(attrs) when is_map(attrs) do
    if loaded?() do
      OpenTelemetry.Tracer.set_attributes(attrs)
    else
      :ok
    end
  end

  defp loaded? do
    Code.ensure_loaded?(OpenTelemetry.Tracer) and
      function_exported?(OpenTelemetry.Tracer, :with_span, 2)
  end

  defp loaded_exporter? do
    Code.ensure_loaded?(:opentelemetry_exporter) and
      function_exported?(:opentelemetry_exporter, :setup, 1)
  end
end
