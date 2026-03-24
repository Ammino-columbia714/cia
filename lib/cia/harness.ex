defmodule CIA.Harness do
  @moduledoc """
  The public harness behaviour and normalization boundary.

  In normal application code, harnesses are configured through `CIA.harness/3`
  as part of a `%CIA.Plan{}`.

  Most callers should not treat this as a separate high-level API surface.
  They should use `CIA.harness/3` unless they are implementing or testing a
  harness adapter.
  """

  alias CIA.MCP
  alias CIA.Tool

  @enforce_keys [:id, :harness]
  defstruct [:id, :harness, :cwd, config: %{}, mcp: %{}, tools: %Tool{}, session: %{}]

  @callback runtime_command(term()) :: {String.t(), [String.t()]}
  @callback start_session(term()) :: {:ok, term(), list()} | {:error, term()}
  @callback stop_session(term()) :: :ok | {:error, term()}
  @callback start_thread(term(), keyword()) :: {:ok, term()} | {:error, term()}
  @callback submit_turn(term(), term(), term(), keyword()) :: {:ok, term()} | {:error, term()}
  @callback steer_turn(term(), term(), term(), keyword()) :: :ok | {:error, term()}
  @callback cancel_turn(term(), term()) :: :ok | {:error, term()}
  @callback resolve(term(), term(), term()) :: :ok | {:error, term()}

  @doc false
  def new(opts) when is_list(opts) do
    with {:ok, id} <- validate_id(Keyword.get(opts, :id)),
         {:ok, harness} <- validate_harness(Keyword.get(opts, :harness)),
         {:ok, config} <- validate_config(opts),
         {:ok, mcp} <- validate_mcp(Keyword.get(opts, :mcp, %{})),
         {:ok, tools} <- validate_tools(Keyword.get(opts, :tools, %Tool{})) do
      {:ok,
       %__MODULE__{
         id: id,
         harness: harness,
         config: config,
         mcp: mcp,
         tools: tools
       }}
    end
  end

  @doc false
  def put_mcp(%__MODULE__{} = harness, %MCP{id: id} = server) do
    %__MODULE__{harness | mcp: Map.put(harness.mcp, id, server)}
  end

  @doc false
  def put_tool(%__MODULE__{} = harness, %Tool{} = delta) do
    %__MODULE__{harness | tools: Tool.merge(harness.tools, delta)}
  end

  @doc false
  def instructions(%__MODULE__{config: config}) when is_map(config) do
    Map.get(config, :instructions) || Map.get(config, "instructions") || []
  end

  @doc false
  def runtime_command(%{harness: harness} = state) do
    with {:ok, module} <- module_for(harness) do
      case module.runtime_command(state) do
        {command, args} when is_binary(command) and is_list(args) -> {:ok, {command, args}}
        other -> {:error, {:invalid_runtime_command, other}}
      end
    end
  end

  @doc false
  def start_session(%{harness: harness} = state) do
    with {:ok, module} <- module_for(harness) do
      module.start_session(state)
    end
  end

  @doc false
  def stop_session(%{harness: harness} = session) do
    with {:ok, module} <- module_for(harness) do
      module.stop_session(session)
    end
  end

  @doc false
  def start_thread(%{harness: harness} = session, opts \\ []) when is_list(opts) do
    with {:ok, module} <- module_for(harness) do
      module.start_thread(session, opts)
    end
  end

  @doc false
  def submit_turn(%{harness: harness} = session, thread_ref, input, opts \\ [])
      when is_list(opts) do
    with {:ok, module} <- module_for(harness) do
      module.submit_turn(session, thread_ref, input, opts)
    end
  end

  @doc false
  def steer_turn(%{harness: harness} = session, turn_ref, input, opts \\ [])
      when is_list(opts) do
    with {:ok, module} <- module_for(harness) do
      module.steer_turn(session, turn_ref, input, opts)
    end
  end

  @doc false
  def cancel_turn(%{harness: harness} = session, turn_ref) do
    with {:ok, module} <- module_for(harness) do
      module.cancel_turn(session, turn_ref)
    end
  end

  @doc false
  def resolve(%{harness: harness} = session, request_id, decision) do
    with {:ok, module} <- module_for(harness) do
      module.resolve(session, request_id, decision)
    end
  end

  ## Helpers

  @doc false
  def module_for(%__MODULE__{harness: harness}), do: module_for(harness)

  @doc false
  def module_for(:codex), do: {:ok, CIA.Harness.Codex}

  @doc false
  def module_for(module) when is_atom(module), do: {:ok, module}

  @doc false
  def module_for(other), do: {:error, {:invalid_harness, other}}

  defp validate_id(id) when is_binary(id) and byte_size(id) > 0, do: {:ok, id}
  defp validate_id(_), do: {:error, {:invalid_id, :expected_non_empty_string}}

  defp validate_harness(nil), do: {:error, {:missing_option, :harness}}
  defp validate_harness(harness) when is_atom(harness), do: {:ok, harness}
  defp validate_harness(_), do: {:error, {:missing_option, :harness}}

  defp validate_config(opts) when is_list(opts) do
    config =
      opts
      |> Keyword.drop([:id, :harness, :mcp, :tools])
      |> Map.new()

    case normalize_instructions(Map.get(config, :instructions) || Map.get(config, "instructions")) do
      {:ok, instructions} ->
        {:ok, Map.put(config, :instructions, instructions)}

      {:error, _reason} = error ->
        error
    end
  end

  defp validate_mcp(mcp) when is_map(mcp) do
    case Enum.reduce_while(mcp, {:ok, %{}}, fn
           {id, %MCP{id: server_id} = server}, {:ok, acc} when server_id == id ->
             {:cont, {:ok, Map.put(acc, id, server)}}

           {_id, %MCP{} = server}, _acc ->
             {:halt, {:error, {:invalid_mcp, {:mismatched_id, server.id}}}}

           {_id, other}, _acc ->
             {:halt, {:error, {:invalid_mcp, other}}}
         end) do
      {:ok, normalized} -> {:ok, normalized}
      {:error, _reason} = error -> error
    end
  end

  defp validate_mcp(_), do: {:error, {:invalid_option, :mcp}}

  defp validate_tools(%Tool{} = tools), do: {:ok, tools}
  defp validate_tools(_), do: {:error, {:invalid_option, :tools}}

  defp normalize_instructions(nil), do: {:ok, []}
  defp normalize_instructions(value) when is_binary(value), do: {:ok, [{:text, value}]}

  defp normalize_instructions(value) when is_list(value) do
    if Keyword.keyword?(value) do
      normalize_instruction_keywords(value)
    else
      Enum.reduce_while(value, {:ok, []}, fn instruction, {:ok, acc} ->
        case normalize_instruction(instruction) do
          {:ok, normalized} -> {:cont, {:ok, acc ++ [normalized]}}
          {:error, _reason} = error -> {:halt, error}
        end
      end)
    end
  end

  defp normalize_instructions(other), do: {:error, {:invalid_option, {:instructions, other}}}

  defp normalize_instruction_keywords(keywords) do
    Enum.reduce_while(keywords, {:ok, []}, fn
      {:inline, text}, {:ok, acc} when is_binary(text) and text != "" ->
        {:cont, {:ok, acc ++ [{:text, text}]}}

      {:files, paths}, {:ok, acc} when is_list(paths) ->
        with {:ok, normalized_paths} <- normalize_file_paths(paths) do
          {:cont, {:ok, acc ++ normalized_paths}}
        end

      {:project_files, enabled}, {:ok, acc} when is_boolean(enabled) ->
        suffix = if enabled, do: [:project_files], else: []
        {:cont, {:ok, acc ++ suffix}}

      {key, value}, _acc ->
        {:halt, {:error, {:invalid_option, {:instructions, {key, value}}}}}
    end)
  end

  defp normalize_instruction(instruction) when is_binary(instruction),
    do: {:ok, {:text, instruction}}

  defp normalize_instruction({:text, text}) when is_binary(text) and text != "",
    do: {:ok, {:text, text}}

  defp normalize_instruction({:file, path}) when is_binary(path) and path != "",
    do: {:ok, {:file, path}}

  defp normalize_instruction(:project_files), do: {:ok, :project_files}

  defp normalize_instruction({:project_files, enabled}) when is_boolean(enabled) do
    case enabled do
      true -> {:ok, :project_files}
      false -> {:ok, {:project_files, false}}
    end
  end

  defp normalize_instruction(other), do: {:error, {:invalid_instruction, other}}

  defp normalize_file_paths(paths) do
    Enum.reduce_while(paths, {:ok, []}, fn
      path, {:ok, acc} when is_binary(path) and path != "" ->
        {:cont, {:ok, acc ++ [{:file, path}]}}

      other, _acc ->
        {:halt, {:error, {:invalid_instruction, {:file, other}}}}
    end)
  end
end
