defmodule CIA.Sandbox.Local do
  @moduledoc false

  @behaviour CIA.Sandbox

  alias CIA.Sandbox.Channel
  alias CIA.Sandbox.Local.Channel.Stdio
  alias CIA.Sandbox.Local.Channel.Watch, as: WatchChannel
  alias CIA.Sandbox.Watch

  @supported_lifecycles [:ephemeral]

  defstruct [:mode, :channel, :lifecycle, metadata: %{}]

  def normalize_config(config) when is_map(config) do
    with {:ok, lifecycle} <- normalize_lifecycle(Map.get(config, :lifecycle, :ephemeral)) do
      {:ok, Map.put(config, :lifecycle, lifecycle)}
    end
  end

  def start(%CIA.Sandbox{provider: :local, config: config, metadata: metadata}, opts)
      when is_list(opts) do
    opts =
      config
      |> Map.to_list()
      |> Keyword.merge(opts)
      |> Keyword.put_new(:metadata, metadata)

    with {:ok, lifecycle} <- normalize_lifecycle(sandbox_lifecycle(opts)),
         {:ok, channel} <- start_channel(opts) do
      {:ok,
       %__MODULE__{
         mode: sandbox_mode(opts),
         channel: channel,
         lifecycle: lifecycle,
         metadata: Keyword.get(opts, :metadata, %{})
       }}
    end
  end

  def stop(%__MODULE__{channel: %Channel{} = channel}) do
    case Process.alive?(channel.pid) do
      true -> Channel.stop(channel)
      false -> :ok
    end
  end

  def cmd(%__MODULE__{}, command, args, opts)
      when is_binary(command) and is_list(args) and is_list(opts) do
    with {:ok, executable, exec_args} <- split_exec_command([command | args]) do
      exec_opts =
        []
        |> maybe_put_exec_cd(Keyword.get(opts, :cwd))
        |> maybe_put_exec_env(Keyword.get(opts, :env))
        |> maybe_put_exec_into(opts)
        |> maybe_put_stderr_to_stdout(Keyword.get(opts, :stderr_to_stdout, false))
        |> maybe_put_exec_timeout(Keyword.get(opts, :timeout))

      System.cmd(executable, exec_args, exec_opts)
    end
  end

  def read(%__MODULE__{}, path, opts) when is_binary(path) and is_list(opts) do
    resolved = resolve_path(path, Keyword.get(opts, :cwd))

    case File.read(resolved) do
      {:ok, contents} ->
        case Keyword.get(opts, :encoding, :binary) do
          :binary -> {:ok, contents}
          :utf8 -> {:ok, contents}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  def write(%__MODULE__{}, path, contents, opts) when is_binary(path) and is_list(opts) do
    resolved = resolve_path(path, Keyword.get(opts, :cwd))

    with :ok <- maybe_mkdir_parent(resolved, Keyword.get(opts, :mkdir_p, false)),
         :ok <- File.write(resolved, IO.iodata_to_binary(contents)),
         :ok <- maybe_chmod(resolved, Keyword.get(opts, :mode)) do
      :ok
    end
  end

  def ls(%__MODULE__{}, path, opts) when is_binary(path) and is_list(opts) do
    resolved = resolve_path(path, Keyword.get(opts, :cwd))
    recursive = Keyword.get(opts, :recursive, false)

    case File.ls(resolved) do
      {:ok, entries} ->
        entries =
          entries
          |> Enum.map(&Path.join(resolved, &1))
          |> Enum.flat_map(&expand_entry(&1, recursive))
          |> Enum.map(&entry_metadata(&1, resolved))

        {:ok, entries}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def mkdir(%__MODULE__{}, path, opts) when is_binary(path) and is_list(opts) do
    resolved = resolve_path(path, Keyword.get(opts, :cwd))

    case Keyword.get(opts, :parents, true) do
      true -> File.mkdir_p(resolved)
      false -> File.mkdir(resolved)
    end
  end

  def rm(%__MODULE__{}, path, opts) when is_binary(path) and is_list(opts) do
    resolved = resolve_path(path, Keyword.get(opts, :cwd))
    recursive = Keyword.get(opts, :recursive, false)
    force = Keyword.get(opts, :force, false)

    result =
      cond do
        recursive -> File.rm_rf(resolved)
        true -> File.rm(resolved)
      end

    normalize_rm_result(result, force)
  end

  def mv(%__MODULE__{}, source, dest, opts)
      when is_binary(source) and is_binary(dest) and is_list(opts) do
    resolved_source = resolve_path(source, Keyword.get(opts, :cwd))
    resolved_dest = resolve_path(dest, Keyword.get(opts, :cwd))

    with :ok <- maybe_mkdir_parent(resolved_dest, Keyword.get(opts, :mkdir_p, false)) do
      File.rename(resolved_source, resolved_dest)
    end
  end

  def cp(%__MODULE__{}, source, dest, opts)
      when is_binary(source) and is_binary(dest) and is_list(opts) do
    resolved_source = resolve_path(source, Keyword.get(opts, :cwd))
    resolved_dest = resolve_path(dest, Keyword.get(opts, :cwd))
    recursive = Keyword.get(opts, :recursive, true)

    with :ok <- maybe_mkdir_parent(resolved_dest, Keyword.get(opts, :mkdir_p, false)) do
      cond do
        File.dir?(resolved_source) and recursive ->
          case File.cp_r(resolved_source, resolved_dest) do
            {:ok, _paths} -> :ok
            {:error, reason, _path} -> {:error, reason}
          end

        true ->
          File.cp(resolved_source, resolved_dest)
      end
    end
  end

  def watch(%__MODULE__{}, paths, opts) when is_list(paths) and is_list(opts) do
    owner = Keyword.get(opts, :owner, self())
    cwd = Keyword.get(opts, :cwd)
    recursive = Keyword.get(opts, :recursive, false)
    interval = Keyword.get(opts, :interval, 250)
    id = watch_id()

    case WatchChannel.start_link(
           id: id,
           owner: owner,
           paths: paths,
           cwd: cwd,
           recursive: recursive,
           interval: interval
         ) do
      {:ok, pid} ->
        {:ok, Watch.new(id, WatchChannel, pid, %{paths: paths, cwd: cwd, recursive: recursive})}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def checkpoint(%__MODULE__{}, _opts),
    do: {:error, {:unsupported_sandbox_operation, :checkpoint}}

  def restore(%__MODULE__{}, _checkpoint, _opts),
    do: {:error, {:unsupported_sandbox_operation, :restore}}

  defp sandbox_mode(opts), do: Keyword.get(opts, :mode, :workspace_write)
  defp sandbox_lifecycle(opts), do: Keyword.get(opts, :lifecycle, :ephemeral)

  defp start_channel(opts) do
    command =
      opts
      |> Keyword.fetch!(:command)
      |> normalize_runtime_command()

    env = Keyword.get(opts, :env, %{})

    case Stdio.start_link(owner: self(), command: command, env: env) do
      {:ok, pid} -> {:ok, Channel.new(Stdio, pid)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp split_exec_command([executable | args]) when is_binary(executable) do
    case resolve_executable(executable) do
      {:ok, resolved} -> {:ok, resolved, args}
      {:error, reason} -> {:error, reason}
    end
  end

  defp split_exec_command(_), do: {:error, {:invalid_option, :command}}

  defp resolve_executable(executable) when is_binary(executable) do
    cond do
      executable == "" ->
        {:error, {:command_not_found, executable}}

      String.contains?(executable, "/") and File.exists?(executable) ->
        {:ok, executable}

      true ->
        case System.find_executable(executable) do
          nil -> {:error, {:command_not_found, executable}}
          resolved -> {:ok, resolved}
        end
    end
  end

  defp maybe_put_exec_cd(opts, nil), do: opts
  defp maybe_put_exec_cd(opts, cwd), do: Keyword.put(opts, :cd, cwd)

  defp maybe_put_exec_env(opts, nil), do: opts
  defp maybe_put_exec_env(opts, env) when env == %{}, do: opts
  defp maybe_put_exec_env(opts, env) when is_list(env), do: Keyword.put(opts, :env, env)

  defp maybe_put_exec_env(opts, env) when is_map(env),
    do: Keyword.put(opts, :env, Map.to_list(env))

  defp maybe_put_exec_into(opts, cmd_opts) when is_list(cmd_opts) do
    case Keyword.fetch(cmd_opts, :into) do
      {:ok, into} -> Keyword.put(opts, :into, into)
      :error -> opts
    end
  end

  defp maybe_put_stderr_to_stdout(opts, true), do: Keyword.put(opts, :stderr_to_stdout, true)
  defp maybe_put_stderr_to_stdout(opts, false), do: opts

  defp maybe_put_exec_timeout(opts, nil), do: opts
  defp maybe_put_exec_timeout(opts, timeout), do: Keyword.put(opts, :timeout, timeout)

  defp normalize_runtime_command({command, args})
       when is_binary(command) and is_list(args),
       do: [command | args]

  defp normalize_runtime_command(command) when is_list(command), do: command

  defp resolve_path(path, nil), do: path
  defp resolve_path(path, cwd), do: Path.expand(path, cwd)

  defp maybe_mkdir_parent(_path, false), do: :ok

  defp maybe_mkdir_parent(path, true) do
    path |> Path.dirname() |> File.mkdir_p()
  end

  defp maybe_chmod(_path, nil), do: :ok

  defp maybe_chmod(path, mode) when is_binary(mode) do
    case Integer.parse(mode, 8) do
      {parsed, ""} -> File.chmod(path, parsed)
      _ -> {:error, {:invalid_option, {:mode, mode}}}
    end
  end

  defp expand_entry(path, true) when is_binary(path) do
    case File.dir?(path) do
      true ->
        [
          path
          | File.ls!(path)
            |> Enum.map(&Path.join(path, &1))
            |> Enum.flat_map(&expand_entry(&1, true))
        ]

      false ->
        [path]
    end
  end

  defp expand_entry(path, _recursive), do: [path]

  defp entry_metadata(path, root) do
    {:ok, stat} = File.stat(path, time: :posix)
    metadata = build_stat_map(path, stat)

    metadata
    |> Map.put(:name, Path.basename(path))
    |> Map.put(:relative_path, Path.relative_to(path, root))
  end

  defp build_stat_map(path, stat) do
    %{
      path: path,
      type: stat.type,
      size: stat.size,
      mode: stat.mode,
      mtime: stat.mtime,
      is_dir: stat.type == :directory
    }
  end

  defp normalize_rm_result({:ok, _paths}, _force), do: :ok
  defp normalize_rm_result(:ok, _force), do: :ok
  defp normalize_rm_result({:error, :enoent}, true), do: :ok
  defp normalize_rm_result({:error, reason}, _force), do: {:error, reason}

  defp watch_id do
    "watch_" <> Integer.to_string(System.unique_integer([:positive, :monotonic]))
  end

  defp normalize_lifecycle(lifecycle) when lifecycle in @supported_lifecycles,
    do: {:ok, lifecycle}

  defp normalize_lifecycle(lifecycle) when lifecycle in [:durable, :attached] do
    {:error, {:unsupported_sandbox_lifecycle, :local, lifecycle}}
  end

  defp normalize_lifecycle(lifecycle) do
    {:error, {:invalid_option, {:lifecycle, lifecycle}}}
  end
end
