defmodule CIA.MCP do
  @moduledoc false

  alias CIA.Tool

  @enforce_keys [:id, :transport]
  defstruct [
    :id,
    :transport,
    :command,
    args: [],
    cwd: nil,
    env: %{},
    url: nil,
    headers: %{},
    enabled: true,
    required: false,
    timeout: %{},
    tools: %Tool{},
    config: %{}
  ]

  def new(id, opts) when is_list(opts) do
    with {:ok, normalized_id} <- validate_id(id),
         {:ok, transport} <- validate_transport(Keyword.get(opts, :transport)),
         :ok <- validate_transport_opts(transport, opts),
         {:ok, env} <- validate_map(opts, :env, %{}),
         {:ok, headers} <- validate_map(opts, :headers, %{}),
         {:ok, timeout} <- validate_timeout(Keyword.get(opts, :timeout, %{})),
         {:ok, tools} <- validate_tools(Keyword.get(opts, :tools, [])) do
      {:ok,
       %__MODULE__{
         id: normalized_id,
         transport: transport,
         command: Keyword.get(opts, :command),
         args: Keyword.get(opts, :args, []),
         cwd: Keyword.get(opts, :cwd),
         env: env,
         url: Keyword.get(opts, :url),
         headers: headers,
         enabled: Keyword.get(opts, :enabled, true),
         required: Keyword.get(opts, :required, false),
         timeout: timeout,
         tools: tools,
         config:
           opts
           |> Keyword.drop([
             :transport,
             :command,
             :args,
             :cwd,
             :env,
             :url,
             :headers,
             :enabled,
             :required,
             :timeout,
             :tools
           ])
           |> Map.new()
       }}
    end
  end

  def new(_id, _opts), do: {:error, {:invalid_option, :mcp}}

  defp validate_id(id) when is_atom(id) or (is_binary(id) and id != ""), do: {:ok, id}
  defp validate_id(other), do: {:error, {:invalid_mcp_id, other}}

  defp validate_transport(:stdio), do: {:ok, :stdio}
  defp validate_transport(:http), do: {:ok, :http}
  defp validate_transport(other), do: {:error, {:invalid_mcp_transport, other}}

  defp validate_transport_opts(:stdio, opts) do
    case Keyword.get(opts, :command) do
      command when is_binary(command) and command != "" -> :ok
      other -> {:error, {:invalid_mcp_command, other}}
    end
  end

  defp validate_transport_opts(:http, opts) do
    case Keyword.get(opts, :url) do
      url when is_binary(url) and url != "" -> :ok
      other -> {:error, {:invalid_mcp_url, other}}
    end
  end

  defp validate_map(opts, key, default) do
    case Keyword.get(opts, key, default) do
      value when is_map(value) -> {:ok, value}
      other -> {:error, {:invalid_option, {key, other}}}
    end
  end

  defp validate_timeout(timeout) when timeout == %{}, do: {:ok, %{}}
  defp validate_timeout(timeout) when timeout == [], do: {:ok, %{}}

  defp validate_timeout(timeout) when is_list(timeout) do
    timeout
    |> Enum.into(%{})
    |> validate_timeout()
  end

  defp validate_timeout(timeout) when is_map(timeout) do
    case Enum.all?(timeout, fn
           {:startup, value} when is_integer(value) and value >= 0 -> true
           {:tool, value} when is_integer(value) and value >= 0 -> true
           {"startup", value} when is_integer(value) and value >= 0 -> true
           {"tool", value} when is_integer(value) and value >= 0 -> true
           _ -> false
         end) do
      true -> {:ok, stringify_timeout_keys(timeout)}
      false -> {:error, {:invalid_option, :timeout}}
    end
  end

  defp validate_timeout(_), do: {:error, {:invalid_option, :timeout}}

  defp validate_tools([]), do: {:ok, %Tool{}}

  defp validate_tools(opts) when is_list(opts) do
    Tool.new(opts)
  end

  defp validate_tools(%Tool{} = tools), do: {:ok, tools}
  defp validate_tools(_), do: {:error, {:invalid_option, :tools}}

  defp stringify_timeout_keys(map) do
    Map.new(map, fn
      {key, value} when is_atom(key) -> {Atom.to_string(key), value}
      pair -> pair
    end)
  end
end
