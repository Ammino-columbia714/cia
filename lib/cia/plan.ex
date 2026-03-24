defmodule CIA.Plan do
  @moduledoc false

  alias CIA.Harness
  alias CIA.MCP
  alias CIA.Tool

  @hook_names [:before_start, :after_start, :before_stop, :after_stop]

  defstruct sandbox: nil, workspace: nil, harness: nil, mcp: %{}, tools: %Tool{}, hooks: %{}

  @doc false
  def new do
    %__MODULE__{}
  end

  @doc false
  def put_sandbox(%__MODULE__{} = plan, opts) when is_list(opts) do
    %__MODULE__{plan | sandbox: plan.sandbox |> merge_config(opts) |> ensure_id("sandbox")}
  end

  @doc false
  def put_workspace(%__MODULE__{} = plan, opts) when is_list(opts) do
    %__MODULE__{plan | workspace: plan.workspace |> merge_config(opts) |> ensure_id("workspace")}
  end

  @doc false
  def put_harness(%__MODULE__{} = plan, opts) when is_list(opts) do
    config =
      harness_opts(plan)
      |> Keyword.merge(opts)
      |> ensure_id("agent")

    put_compiled_harness(plan, config)
  end

  @doc false
  def put_mcp(%__MODULE__{} = plan, id, opts) when is_list(opts) do
    case MCP.new(id, opts) do
      {:ok, %MCP{} = server} ->
        plan
        |> Map.update!(:mcp, &Map.put(&1, server.id, server))
        |> sync_harness()

      {:error, reason} ->
        raise ArgumentError, "invalid MCP configuration: #{inspect(reason)}"
    end
  end

  @doc false
  def put_tool(%__MODULE__{} = plan, opts) when is_list(opts) do
    case Tool.new(opts) do
      {:ok, %Tool{} = tool} ->
        plan
        |> Map.update!(:tools, &Tool.merge(&1, tool))
        |> sync_harness()

      {:error, reason} ->
        raise ArgumentError, "invalid tool configuration: #{inspect(reason)}"
    end
  end

  @doc false
  def put_hook(%__MODULE__{} = plan, hook_name, fun) when is_function(fun, 1) do
    case hook_name in @hook_names do
      true ->
        hooks = Map.update(plan.hooks, hook_name, [fun], &(&1 ++ [fun]))
        %__MODULE__{plan | hooks: hooks}

      false ->
        raise ArgumentError, "unsupported hook: #{inspect(hook_name)}"
    end
  end

  defp merge_config(nil, opts), do: Enum.into(opts, %{})
  defp merge_config(config, opts), do: Map.merge(config, Enum.into(opts, %{}))

  defp harness_opts(%__MODULE__{harness: nil, mcp: mcp, tools: tools}) do
    [mcp: mcp, tools: tools]
  end

  defp harness_opts(%__MODULE__{
         harness: %Harness{id: id, harness: harness, config: config},
         mcp: mcp,
         tools: tools
       }) do
    [id: id, harness: harness, mcp: mcp, tools: tools] ++ Map.to_list(config)
  end

  defp sync_harness(%__MODULE__{harness: nil} = plan), do: plan

  defp sync_harness(%__MODULE__{} = plan) do
    plan
    |> harness_opts()
    |> put_compiled_harness(plan)
  end

  defp put_compiled_harness(config, %__MODULE__{} = plan) when is_list(config) do
    put_compiled_harness(plan, config)
  end

  defp put_compiled_harness(%__MODULE__{} = plan, config) when is_list(config) do
    case Harness.new(config) do
      {:ok, %Harness{} = harness} -> %__MODULE__{plan | harness: harness}
      {:error, reason} -> raise ArgumentError, "invalid harness configuration: #{inspect(reason)}"
    end
  end

  defp ensure_id(config, prefix) when is_map(config) do
    Map.put_new_lazy(config, :id, fn ->
      prefix <> "_" <> Integer.to_string(System.unique_integer([:positive]))
    end)
  end

  defp ensure_id(opts, prefix) when is_list(opts) do
    Keyword.put_new_lazy(opts, :id, fn ->
      prefix <> "_" <> Integer.to_string(System.unique_integer([:positive]))
    end)
  end
end
