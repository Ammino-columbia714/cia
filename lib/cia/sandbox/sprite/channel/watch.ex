defmodule CIA.Sandbox.Sprite.Channel.Watch do
  @moduledoc false

  @behaviour CIA.Sandbox.Watch

  use WebSockex

  @default_base_url "https://api.sprites.dev"

  def start_link(opts) when is_list(opts) do
    owner = Keyword.fetch!(opts, :owner)
    id = Keyword.fetch!(opts, :id)
    name = Keyword.fetch!(opts, :name)
    token = Keyword.fetch!(opts, :token)
    base_url = Keyword.get(opts, :base_url, @default_base_url) || @default_base_url
    paths = Keyword.fetch!(opts, :paths)
    cwd = Keyword.get(opts, :cwd)
    recursive = Keyword.get(opts, :recursive, false)

    state = %{
      id: id,
      owner: owner,
      owner_ref: Process.monitor(owner),
      name: name,
      token: token,
      base_url: base_url,
      paths: paths,
      cwd: cwd,
      recursive: recursive
    }

    WebSockex.start_link(
      ws_url(base_url, name),
      __MODULE__,
      state,
      extra_headers: [{"authorization", "Bearer #{token}"}]
    )
  end

  @impl true
  def stop(pid, timeout \\ 5_000) when is_pid(pid) do
    GenServer.stop(pid, :normal, timeout)
  end

  @impl true
  def set_owner(pid, owner) when is_pid(pid) and is_pid(owner) do
    WebSockex.cast(pid, {:set_owner, owner})
  end

  @impl true
  def handle_connect(_conn, state) do
    {:reply, {:text, Jason.encode!(subscribe_message(state))}, state}
  end

  @impl true
  def handle_cast({:set_owner, owner}, state) do
    Process.demonitor(state.owner_ref, [:flush])
    {:ok, %{state | owner: owner, owner_ref: Process.monitor(owner)}}
  end

  @impl true
  def handle_frame({:text, payload}, state) do
    case Jason.decode(payload) do
      {:ok, %{"type" => type} = _message} when type in ["ready", "watching"] ->
        notify_owner(state, :ready)
        {:ok, state}

      {:ok, %{"type" => "error"} = message} ->
        notify_owner(state, {:error, message})
        {:ok, state}

      {:ok, message} ->
        notify_owner(state, {:event, normalize_event(message)})
        {:ok, state}

      {:error, reason} ->
        notify_owner(state, {:error, reason})
        {:ok, state}
    end
  end

  def handle_frame(_frame, state) do
    {:ok, state}
  end

  @impl true
  def handle_disconnect(%{reason: reason}, state) do
    notify_owner(state, {:error, {:disconnect, reason}})
    {:ok, state}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{owner_ref: ref} = state) do
    {:close, state}
  end

  @impl true
  def handle_info(_message, state) do
    {:ok, state}
  end

  @impl true
  def terminate(_reason, state) do
    notify_owner(state, :closed)
    :ok
  end

  defp subscribe_message(state) do
    %{
      type: "watch",
      paths: state.paths,
      recursive: state.recursive,
      workingDir: state.cwd
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp normalize_event(message) when is_map(message) do
    %{
      type: normalize_event_type(Map.get(message, "event") || Map.get(message, "type")),
      path: Map.get(message, "path"),
      timestamp: Map.get(message, "timestamp"),
      size: Map.get(message, "size"),
      is_dir: Map.get(message, "isDir", false),
      raw: message
    }
  end

  defp normalize_event_type("create"), do: :create
  defp normalize_event_type("write"), do: :write
  defp normalize_event_type("remove"), do: :remove
  defp normalize_event_type("rename"), do: :rename
  defp normalize_event_type("chmod"), do: :chmod
  defp normalize_event_type("chown"), do: :chown
  defp normalize_event_type(other) when is_binary(other), do: String.to_atom(other)
  defp normalize_event_type(other), do: other

  defp notify_owner(%{owner: owner, id: id}, payload) when is_pid(owner) do
    Kernel.send(owner, {:cia_sandbox_watch, id, payload})
  end

  defp ws_url(base_url, name) do
    uri = URI.parse(base_url)

    %URI{
      scheme: ws_scheme(uri.scheme),
      host: uri.host,
      port: if(uri.port in [80, 443, nil], do: nil, else: uri.port),
      path: "/v1/sprites/#{name}/fs/watch"
    }
    |> URI.to_string()
  end

  defp ws_scheme("https"), do: "wss"
  defp ws_scheme("http"), do: "ws"
  defp ws_scheme("wss"), do: "wss"
  defp ws_scheme("ws"), do: "ws"
  defp ws_scheme(_), do: "wss"
end
