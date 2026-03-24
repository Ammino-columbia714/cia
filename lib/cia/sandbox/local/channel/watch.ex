defmodule CIA.Sandbox.Local.Channel.Watch do
  @moduledoc false

  @behaviour CIA.Sandbox.Watch

  use GenServer

  @default_interval 250

  def start_link(opts) when is_list(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  @impl true
  def stop(pid, timeout \\ 5_000) when is_pid(pid) do
    GenServer.stop(pid, :normal, timeout)
  end

  @impl true
  def set_owner(pid, owner) when is_pid(pid) and is_pid(owner) do
    GenServer.call(pid, {:set_owner, owner})
  end

  @impl true
  def init(opts) do
    owner = Keyword.fetch!(opts, :owner)
    id = Keyword.fetch!(opts, :id)
    paths = Keyword.fetch!(opts, :paths)
    cwd = Keyword.get(opts, :cwd)
    recursive = Keyword.get(opts, :recursive, false)
    interval = Keyword.get(opts, :interval, @default_interval)

    state = %{
      id: id,
      owner: owner,
      owner_ref: Process.monitor(owner),
      paths: paths,
      cwd: cwd,
      recursive: recursive,
      interval: interval,
      snapshot: snapshot(paths, cwd, recursive)
    }

    notify_owner(state, :ready)
    schedule_poll(interval)
    {:ok, state}
  end

  @impl true
  def handle_call({:set_owner, owner}, _from, state) do
    Process.demonitor(state.owner_ref, [:flush])
    new_state = %{state | owner: owner, owner_ref: Process.monitor(owner)}
    {:reply, :ok, new_state}
  end

  @impl true
  def handle_info(:poll, state) do
    new_snapshot = snapshot(state.paths, state.cwd, state.recursive)
    Enum.each(diff_snapshot(state.snapshot, new_snapshot), &notify_owner(state, {:event, &1}))
    schedule_poll(state.interval)
    {:noreply, %{state | snapshot: new_snapshot}}
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{owner_ref: ref} = state) do
    {:stop, :normal, state}
  end

  def handle_info(_message, state) do
    {:noreply, state}
  end

  @impl true
  def terminate(_reason, state) do
    notify_owner(state, :closed)
    :ok
  end

  defp schedule_poll(interval) do
    Process.send_after(self(), :poll, interval)
  end

  defp snapshot(paths, cwd, recursive) do
    Enum.reduce(paths, %{}, fn path, acc ->
      resolved = resolve_path(path, cwd)
      Map.merge(acc, snapshot_path(resolved, recursive))
    end)
  end

  defp snapshot_path(path, recursive) do
    cond do
      File.regular?(path) ->
        case file_metadata(path) do
          {:ok, metadata} -> %{path => metadata}
          {:error, _reason} -> %{}
        end

      File.dir?(path) ->
        path
        |> collect_directory_entries(recursive)
        |> Enum.reduce(%{}, fn entry, acc ->
          case file_metadata(entry) do
            {:ok, metadata} -> Map.put(acc, entry, metadata)
            {:error, _reason} -> acc
          end
        end)

      true ->
        %{}
    end
  end

  defp collect_directory_entries(path, recursive) do
    entries =
      case File.ls(path) do
        {:ok, children} -> Enum.map(children, &Path.join(path, &1))
        {:error, _reason} -> []
      end

    Enum.flat_map(entries, fn entry ->
      cond do
        recursive and File.dir?(entry) -> [entry | collect_directory_entries(entry, true)]
        true -> [entry]
      end
    end)
  end

  defp file_metadata(path) do
    case File.stat(path, time: :posix) do
      {:ok, stat} ->
        {:ok,
         %{
           path: path,
           type: stat.type,
           size: stat.size,
           mtime: stat.mtime,
           mode: stat.mode,
           is_dir: stat.type == :directory
         }}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp diff_snapshot(old_snapshot, new_snapshot) do
    created =
      new_snapshot
      |> Map.drop(Map.keys(old_snapshot))
      |> Map.values()
      |> Enum.map(&event_payload(:create, &1))

    removed =
      old_snapshot
      |> Map.drop(Map.keys(new_snapshot))
      |> Map.values()
      |> Enum.map(&event_payload(:remove, &1))

    changed =
      old_snapshot
      |> Enum.reduce([], fn {path, old_meta}, acc ->
        case Map.fetch(new_snapshot, path) do
          {:ok, new_meta} ->
            if changed?(old_meta, new_meta) do
              [event_payload(:write, new_meta) | acc]
            else
              acc
            end

          :error ->
            acc
        end
      end)
      |> Enum.reverse()

    created ++ changed ++ removed
  end

  defp changed?(old_meta, new_meta) do
    old_meta.size != new_meta.size or old_meta.mtime != new_meta.mtime or
      old_meta.mode != new_meta.mode
  end

  defp event_payload(type, metadata) do
    %{
      type: type,
      path: metadata.path,
      timestamp: DateTime.utc_now(),
      size: metadata.size,
      is_dir: metadata.is_dir
    }
  end

  defp resolve_path(path, nil), do: Path.expand(path)
  defp resolve_path(path, cwd), do: Path.expand(path, cwd)

  defp notify_owner(%{owner: owner, id: id}, payload) when is_pid(owner) do
    Kernel.send(owner, {:cia_sandbox_watch, id, payload})
  end
end
