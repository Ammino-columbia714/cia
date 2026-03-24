defmodule CIA.Sandbox.Watch do
  @moduledoc """
  A handle for a live sandbox filesystem watch.

  Watch handles are returned by `CIA.Sandbox.watch/3`. They are public wrappers
  around provider-specific watch processes and store the watch identifier, the
  provider watch module, the provider watch pid, and provider metadata.

  Watch events are delivered to an owner process as:

      {:cia_sandbox_watch, watch_id, payload}

  Payloads are normalized at the outer contract level and include values such
  as `:ready`, `{:event, event}`, `{:error, reason}`, and `:closed`.

  `metadata` stores provider-supplied watch configuration such as the watched
  paths, `cwd`, and whether the watch is recursive.

  Use `CIA.Sandbox.unwatch/1` or `stop/1` to stop a watch. `set_owner/2` can be
  used to transfer delivery of watch events to another process when supported by
  the active provider.
  """

  @callback stop(pid(), timeout()) :: :ok | {:error, term()}
  @callback set_owner(pid(), pid()) :: :ok | {:error, term()}

  defstruct [:id, :module, :pid, metadata: %{}]

  @type t :: %__MODULE__{
          id: String.t(),
          module: module(),
          pid: pid(),
          metadata: map()
        }

  def new(id, module, pid, metadata \\ %{})
      when is_binary(id) and is_atom(module) and is_pid(pid) and is_map(metadata) do
    %__MODULE__{id: id, module: module, pid: pid, metadata: metadata}
  end

  def stop(%__MODULE__{module: module, pid: pid}, timeout \\ 5_000) do
    module.stop(pid, timeout)
  end

  def set_owner(%__MODULE__{module: module, pid: pid}, owner) when is_pid(owner) do
    module.set_owner(pid, owner)
  end
end
