defmodule CIA.Sandbox do
  @moduledoc """
  A first-class sandbox runtime API.

  Sandboxes represent the compute or runtime layer where code can execute,
  independent from any specific workspace or agent session.

  `CIA.Sandbox` is the public handle for both sandbox configuration and live
  sandbox runtimes.

  A sandbox created with `new/1` is configuration-only until it's started:

      {:ok, sandbox} =
        CIA.Sandbox.new(
          id: "sandbox_1",
          provider: :local,
          mode: :workspace_write
        )

      sandbox.status
      #=> :configured

  Starting it with `start/2` returns the same public handle with provider
  runtime state attached in `sandbox.runtime`:

      {:ok, running_sandbox} =
        CIA.Sandbox.start(sandbox, command: ["/bin/sh", "-lc", "sleep 30"])

      running_sandbox.status
      #=> :running

  Most public operations in this module expect that started handle and operate
  against the live runtime stored inside it.

  `CIA.Sandbox` intentionally normalizes the public API across providers while
  keeping provider runtime structs internal. The current built-in providers are:

    * `:local`

    * `:sprite`

  You will usually interact with sandboxes in one of two places:

    * inside CIA agent lifecycle hooks such as `before_start/2`

    * directly, when you want to provision and manage a sandbox independently
      of a running CIA agent

  ## Command And Filesystem APIs

  `CIA.Sandbox` exposes a normalized set of command and filesystem operations.

  These functions are intended to be the public, provider-agnostic surface for
  interacting with sandbox contents.

  ## Filesystem Watches

  Filesystem watches let you subscribe to file changes inside a live sandbox
  runtime.

  In practice, the most natural place to start a watch is inside
  `CIA.before_start/2`.

  `before_start/2` receives the live sandbox after provisioning has completed
  but before the harness session starts. That hook runs inside the CIA agent
  server process, so a watch created there is owned by the long-lived agent
  process rather than by some temporary caller.

  That means you can start a watch during startup and let the agent forward
  later events automatically:

      CIA.new()
      |> CIA.sandbox(:local)
      |> CIA.before_start(fn %{sandbox: sandbox} ->
        case CIA.Sandbox.watch(sandbox, ["/workspace"], recursive: true) do
          {:ok, _watch} -> :ok
          {:error, reason} -> {:error, reason}
        end
      end)

  After the hook returns, watch messages continue arriving at the agent server
  and CIA rebroadcasts them to agent subscribers as:

      {:cia, agent, {:sandbox, :watch, watch_id, payload}}

  This is the highest-level watch flow in CIA today. It is the right fit when
  you want filesystem activity to become part of the agent's observable runtime
  stream.

  There is one caveat: a watch started in `before_start/2` may emit `:ready` or
  other very early events before external subscribers have attached with
  `CIA.subscribe/2`. The watch still stays alive and later events are still
  forwarded, but startup-time events are not guaranteed to be observed from
  outside the agent.

  Watches are useful whenever file changes are part of the control flow. Common
  examples include:

    * waiting for a generated file to appear after setup work

    * observing agent-written files during a run

    * forwarding file activity to another process for logging or UI updates

    * detecting when a background process has finished producing output

  `watch/3` returns a `%CIA.Sandbox.Watch{}` handle. That handle represents a
  live provider watch process and can later be passed to `unwatch/1` to stop
  delivery. When you start a watch inside `before_start/2`, keeping that handle
  is only necessary if you plan to stop or transfer the watch explicitly later.

  Watches send messages to an owner process. By default that owner is the
  caller, but you can override it with `owner: pid` when starting the watch.
  All built-in providers deliver events with the same outer message shape:

      {:cia_sandbox_watch, watch_id, payload}

  The payload is one of:

    * `:ready` once the watch is active and event delivery has started

    * `{:event, event}` for a filesystem event

    * `{:error, reason}` when the provider encounters a watch error

    * `:closed` when the watch process terminates

  Event payloads are normalized to maps and typically include:

    * `:type` such as `:create`, `:write`, `:remove`, `:rename`, or provider-
      specific event atoms

    * `:path` for the affected file or directory

    * `:timestamp` when available

    * `:size` and `:is_dir` when available

  For example:

      watch_id = watch.id

      receive do
        {:cia_sandbox_watch, ^watch_id, :ready} -> :ok
      after
        5_000 -> {:error, :watch_timeout}
      end

      receive do
        {:cia_sandbox_watch, ^watch_id, {:event, %{type: :write, path: "/workspace/demo.txt"}}} ->
          :ok
      after
        5_000 -> {:error, :watch_timeout}
      end

  Watch behavior is provider dependent behind the normalized interface:

    * the local provider currently uses polling, so events are best-effort and
      governed by the configured `:interval`

    * the Sprite provider streams remote watch events over its watch channel

  You can also use the lower-level sandbox watch API directly when a lifecycle
  hook needs to block on a specific filesystem side effect before startup
  continues:

      parent = self()

      CIA.new()
      |> CIA.sandbox(:local)
      |> CIA.before_start(fn %{sandbox: sandbox} ->
        with {:ok, watch} <-
               CIA.Sandbox.watch(sandbox, ["/workspace"], owner: parent, recursive: true),
             {"", 0} <-
               CIA.Sandbox.cmd(sandbox, "/bin/sh", [
                 "-lc",
                 "mkdir -p /workspace/tmp && (sleep 1; touch /workspace/tmp/ready) &"
               ]),
             :ok <- await_watch_path(watch.id, "/workspace/tmp/ready") do
          CIA.Sandbox.unwatch(watch)
        else
          {:error, reason} -> {:error, reason}
          {_output, status} -> {:error, {:setup_failed, status}}
        end
      end)

      defp await_watch_path(watch_id, path) do
        receive do
          {:cia_sandbox_watch, ^watch_id, {:event, %{path: ^path}}} -> :ok
        after
          5_000 -> {:error, :watch_timeout}
        end
      end

  Outside the CIA lifecycle entirely, you can consume the raw watch messages
  yourself with `CIA.Sandbox.watch/3` and `CIA.Sandbox.unwatch/1`.

  ## Checkpoints

  Checkpoints are point-in-time snapshots of a live sandbox runtime.

  A checkpoint captures sandbox state after some meaningful setup step so that
  you can later restore back to that state without rebuilding everything from
  scratch. In practice, that usually means snapshotting a sandbox after you have
  already done the expensive or repetitive work:

    * cloning repositories

    * installing dependencies

    * writing seed configuration

    * compiling toolchains or generated artifacts

    * preparing known-good fixture data

  Restoring a checkpoint gives you a fast way to return to that prepared state.
  This is especially useful for durable or attached sandboxes where you want to
  reuse the same environment across multiple agent runs but still reset the
  filesystem back to something predictable.

  Checkpoints are provider dependent. Some providers can snapshot and restore a
  live runtime directly, while others may return
  `{:error, {:unsupported_sandbox_operation, op}}`. For example, the built-in
  local provider does not currently implement checkpoint support.

  Common reasons to use checkpoints include:

    * reducing startup time for durable sandboxes by avoiding repeated setup

    * keeping a known-good project baseline that agents can freely mutate and
      then restore

    * recovering from failed experiments without reprovisioning the entire
      environment

  Checkpoints fit naturally into CIA's normal lifecycle hooks because those
  hooks already run at the boundary where you prepare sandbox state for an
  agent. Two common patterns are:

  1. Restore a known baseline in `before_start/2` before the harness session
     begins.
  2. Create or refresh a checkpoint after provisioning work completes so the
     next start can reuse it.

  For example, you might restore a previously saved baseline before each agent
  run:

      CIA.new()
      |> CIA.sandbox(
        :sprite,
        lifecycle: :durable,
        name: "my-shared-sandbox",
        token: System.fetch_env!("CIA_SPRITE_TOKEN")
      )
      |> CIA.before_start(fn %{sandbox: sandbox} ->
        case CIA.Sandbox.restore(sandbox, "project-baseline") do
          :ok -> :ok
          {:error, {:unsupported_sandbox_operation, :restore}} -> :ok
          {:error, reason} -> {:error, reason}
        end
      end)

  Or you might create a checkpoint after expensive setup is complete so later
  runs can restore it:

      parent = self()

      CIA.new()
      |> CIA.sandbox(
        :sprite,
        lifecycle: :durable,
        name: "my-shared-sandbox",
        token: System.fetch_env!("CIA_SPRITE_TOKEN")
      )
      |> CIA.before_start(fn %{sandbox: sandbox} ->
        with {"", 0} <- CIA.Sandbox.cmd(sandbox, "mkdir", ["-p", "/workspace"]),
             {"", 0} <- CIA.Sandbox.cmd(sandbox, "git", ["clone", "repo", "/workspace/repo"]),
             {"", 0} <- CIA.Sandbox.cmd(sandbox, "npm", ["install"], cwd: "/workspace/repo"),
             {:ok, checkpoint} <- CIA.Sandbox.checkpoint(sandbox, label: "repo-ready") do
          send(parent, {:sandbox_checkpoint, checkpoint})
          :ok
        else
          {:error, {:unsupported_sandbox_operation, :checkpoint}} -> :ok
          {_output, status} -> {:error, {:setup_failed, status}}
          {:error, reason} -> {:error, reason}
        end
      end)

  In both cases, the important idea is the same: use checkpoints to separate
  expensive sandbox preparation from the agent work that happens afterward.
  That keeps agent startup faster and makes repeated runs more deterministic.
  """

  alias CIA.Sandbox.{Checkpoint, Watch}

  @enforce_keys [:id, :provider]
  defstruct [:id, :provider, :runtime, config: %{}, metadata: %{}, status: :configured]

  @callback start(term(), keyword()) :: {:ok, term()} | {:error, term()}
  @callback stop(term()) :: :ok | {:error, term()}
  @callback cmd(term(), String.t(), [String.t()], keyword()) ::
              {term(), integer()} | {:error, term()}
  @callback read(term(), String.t(), keyword()) :: {:ok, term()} | {:error, term()}
  @callback write(term(), String.t(), iodata(), keyword()) :: :ok | {:error, term()}
  @callback ls(term(), String.t(), keyword()) :: {:ok, list()} | {:error, term()}
  @callback mkdir(term(), String.t(), keyword()) :: :ok | {:error, term()}
  @callback rm(term(), String.t(), keyword()) :: :ok | {:error, term()}
  @callback mv(term(), String.t(), String.t(), keyword()) :: :ok | {:error, term()}
  @callback cp(term(), String.t(), String.t(), keyword()) :: :ok | {:error, term()}
  @callback watch(term(), [String.t()], keyword()) :: {:ok, Watch.t()} | {:error, term()}
  @callback checkpoint(term(), keyword()) :: {:ok, Checkpoint.t()} | {:error, term()}
  @callback restore(term(), term(), keyword()) :: :ok | {:error, term()}
  @callback normalize_config(map()) :: {:ok, map()} | {:error, term()}
  @optional_callbacks normalize_config: 1

  @doc """
  Builds sandbox configuration.

  Returns `{:ok, sandbox}` on success, or `{:error, reason}` on failure.

  This creates a `%CIA.Sandbox{}` configuration struct. It does not start a
  live sandbox runtime on its own; pass the returned value to `start/2` to
  provision the runtime.

  ## Options

    * `:id` - sandbox identifier

    * `:provider` - sandbox provider, such as `:local`, `:sprite`, or a module which
      implements the Sandbox provider contract

    * `:metadata` - caller-defined metadata stored separately from provider config

  All other options are treated as provider-specific configuration and are
  normalized by the selected sandbox provider when supported.
  """
  def new(opts) when is_list(opts) do
    with {:ok, id} <- validate_id(Keyword.get(opts, :id)),
         {:ok, provider} <- validate_provider(Keyword.get(opts, :provider)),
         {:ok, metadata} <- validate_metadata(Keyword.get(opts, :metadata, %{})),
         {:ok, config} <-
           opts
           |> Keyword.drop([:id, :provider, :metadata])
           |> Map.new()
           |> normalize_config(provider) do
      {:ok,
       %__MODULE__{
         id: id,
         provider: provider,
         config: config,
         metadata: metadata,
         runtime: nil,
         status: :configured
       }}
    end
  end

  @doc """
  Starts a live sandbox runtime from sandbox configuration.

  Returns `{:ok, sandbox}` on success, or `{:error, reason}` on failure.

  The returned sandbox is the same public `%CIA.Sandbox{}` handle, updated with
  provider runtime state in `sandbox.runtime` and `sandbox.status == :running`.

  ## Options

  All options are passthrough directly to the provider and should be considered
  provider specific.
  """
  def start(sandbox, opts \\ [])

  def start(%__MODULE__{runtime: nil} = sandbox, opts) do
    with {:ok, module} <- module_for(sandbox) do
      case module.start(sandbox, opts) do
        {:ok, runtime} ->
          {:ok, %__MODULE__{sandbox | runtime: runtime, status: :running}}

        {:error, _reason} = error ->
          error
      end
    end
  end

  def start(%__MODULE__{runtime: _runtime}, _opts) do
    {:error, :sandbox_already_started}
  end

  def start(other, opts) do
    with {:ok, module} <- module_for(other) do
      module.start(other, opts)
    end
  end

  @doc """
  Runs a one-shot command inside a live sandbox runtime.

  Returns `{:ok, {output, exit_status}}` on successful execution. Transport or
  provider failures are returned as `{:error, reason}`.

  This mirrors the shape of `System.cmd/3`, but runs against a CIA sandbox
  runtime instead of the local OS process environment.

  ## Options

    * `:cwd` - current directory

    * `:env` - environment variables to pass through to command

    * `:into` - a collectable to collect output values into

    * `:stderr_to_stdout` - redirects stderr to stdout when `true`

    * `:timeout` - command execution timeout

  All other options are passthrough directly to the provider and should
  be considered provider specific.
  """
  def cmd(sandbox, command, args \\ [], opts \\ [])
      when is_binary(command) and is_list(args) and is_list(opts) do
    delegate_sandbox_op(sandbox, :cmd, [command, args, opts])
  end

  @doc """
  Reads file contents from a live sandbox runtime.

  Returns `{:ok, contents}` on success, or `{:error, reason}` on failure.

  ## Options

    * `:cwd` - resolves relative paths against the given working directory

    * `:encoding` - requested file encoding, such as `:binary` or `:utf8`

  All other options are passthrough directly to the provider and should be
  considered provider specific.
  """
  def read(sandbox, path, opts \\ []) when is_binary(path) and is_list(opts) do
    delegate_sandbox_op(sandbox, :read, [path, opts])
  end

  @doc """
  Writes file contents inside a live sandbox runtime.

  Returns `:ok` on success, or `{:error, reason}` on failure.

  ## Options

    * `:cwd` - resolves relative paths against the given working directory

    * `:mkdir_p` - creates parent directories before writing when `true`

    * `:mode` - file mode to apply after writing

  All other options are passthrough directly to the provider and should be
  considered provider specific.
  """
  def write(sandbox, path, contents, opts \\ [])
      when is_binary(path) and is_list(opts) do
    delegate_sandbox_op(sandbox, :write, [path, contents, opts])
  end

  @doc """
  Lists directory contents from a live sandbox runtime.

  Returns `{:ok, entries}` on success, or `{:error, reason}` on failure.

  ## Options

    * `:cwd` - resolves relative paths against the given working directory

    * `:recursive` - includes nested entries when `true`

  All other options are passthrough directly to the provider and should be
  considered provider specific.
  """
  def ls(sandbox, path, opts \\ []) when is_binary(path) and is_list(opts) do
    delegate_sandbox_op(sandbox, :ls, [path, opts])
  end

  @doc """
  Creates a directory inside a live sandbox runtime.

  Returns `:ok` on success, or `{:error, reason}` on failure.

  ## Options

    * `:cwd` - resolves relative paths against the given working directory

    * `:parents` - creates parent directories when `true`

  All other options are passthrough directly to the provider and should be
  considered provider specific.
  """
  def mkdir(sandbox, path, opts \\ []) when is_binary(path) and is_list(opts) do
    delegate_sandbox_op(sandbox, :mkdir, [path, opts])
  end

  @doc """
  Removes a file or directory from a live sandbox runtime.

  Returns `:ok` on success, or `{:error, reason}` on failure.

  ## Options

    * `:cwd` - resolves relative paths against the given working directory

    * `:recursive` - removes directory trees recursively when `true`

    * `:force` - suppresses missing-path errors when `true`

  All other options are passthrough directly to the provider and should be
  considered provider specific.
  """
  def rm(sandbox, path, opts \\ []) when is_binary(path) and is_list(opts) do
    delegate_sandbox_op(sandbox, :rm, [path, opts])
  end

  @doc """
  Renames or moves a file or directory inside a live sandbox runtime.

  Returns `:ok` on success, or `{:error, reason}` on failure.

  ## Options

    * `:cwd` - resolves relative paths against the given working directory

    * `:mkdir_p` - creates the destination parent directory when `true`

  All other options are passthrough directly to the provider and should be
  considered provider specific.
  """
  def mv(sandbox, source, dest, opts \\ [])
      when is_binary(source) and is_binary(dest) and is_list(opts) do
    delegate_sandbox_op(sandbox, :mv, [source, dest, opts])
  end

  @doc """
  Copies a file or directory inside a live sandbox runtime.

  Returns `:ok` on success, or `{:error, reason}` on failure.

  ## Options

    * `:cwd` - resolves relative paths against the given working directory

    * `:mkdir_p` - creates the destination parent directory when `true`

    * `:recursive` - copies directory trees recursively when `true`

    * `:preserve` - preserves source attributes when supported by the provider

  All other options are passthrough directly to the provider and should be
  considered provider specific.
  """
  def cp(sandbox, source, dest, opts \\ [])
      when is_binary(source) and is_binary(dest) and is_list(opts) do
    delegate_sandbox_op(sandbox, :cp, [source, dest, opts])
  end

  @doc """
  Starts a filesystem watch against a live sandbox runtime.

  Returns `{:ok, watch}` on success, or `{:error, reason}` on failure.

  ## Options

    * `:owner` - process that receives watch events

    * `:cwd` - resolves relative paths against the given working directory

    * `:recursive` - watches nested paths when `true`

    * `:interval` - polling interval for providers that use polling

  All other options are passthrough directly to the provider and should be
  considered provider specific.
  """
  def watch(sandbox, paths, opts \\ []) when is_list(opts) do
    paths = normalize_watch_paths(paths)
    delegate_sandbox_op(sandbox, :watch, [paths, opts])
  end

  @doc """
  Stops a previously started sandbox filesystem watch.

  Returns `:ok` on success, or `{:error, reason}` on failure.
  """
  def unwatch(%Watch{} = watch) do
    Watch.stop(watch)
  end

  @doc """
  Creates a sandbox checkpoint.

  Returns `{:ok, checkpoint}` on success, or `{:error, reason}` on failure.

  The returned checkpoint is a `%CIA.Sandbox.Checkpoint{}` handle. Most callers
  will either store that handle directly or persist `checkpoint.id` and later
  restore from the binary name.

  ## Options

  All options are passthrough directly to the provider and should be considered
  provider specific.
  """
  def checkpoint(sandbox, opts \\ []) when is_list(opts) do
    delegate_sandbox_op(sandbox, :checkpoint, [opts])
  end

  @doc """
  Restores a sandbox checkpoint.

  Returns `:ok` on success, or `{:error, reason}` on failure.

  `checkpoint` may be either:

    * a checkpoint name binary such as `"project-baseline"`

    * a `%CIA.Sandbox.Checkpoint{}` returned by `checkpoint/2`

  Prefer the binary form when you already know the checkpoint name. Use the
  struct form when you are round-tripping the handle returned by a provider and
  want CIA to preserve any provider-specific restore reference stored inside it.

  ## Options

  All options are passthrough directly to the provider and should be considered
  provider specific.
  """
  def restore(sandbox, checkpoint, opts \\ []) when is_list(opts) do
    delegate_sandbox_op(sandbox, :restore, [checkpoint, opts])
  end

  @doc """
  Stops a live sandbox runtime.

  Returns `{:ok, sandbox}` on success, or `{:error, reason}` on failure.
  """
  def stop(%__MODULE__{runtime: nil} = sandbox) do
    {:ok, %__MODULE__{sandbox | status: :stopped}}
  end

  def stop(%__MODULE__{runtime: runtime} = sandbox) do
    with {:ok, module} <- module_for(sandbox) do
      case module.stop(runtime) do
        :ok ->
          {:ok, %__MODULE__{sandbox | runtime: nil, status: :stopped}}

        {:error, _reason} = error ->
          error
      end
    end
  end

  def stop(other) do
    with {:ok, module} <- module_for(other) do
      module.stop(other)
    end
  end

  ## Helpers

  @doc false
  def runtime(%__MODULE__{runtime: runtime}), do: runtime
  def runtime(runtime), do: runtime

  @doc false
  def running?(%__MODULE__{runtime: runtime, status: :running}), do: not is_nil(runtime)
  def running?(%__MODULE__{}), do: false
  def running?(%{channel: %{pid: pid}}) when is_pid(pid), do: Process.alive?(pid)
  def running?(_other), do: false

  @doc false
  def mode(%__MODULE__{runtime: runtime, config: config}) when is_map(config) do
    case runtime do
      %{mode: mode} -> mode
      _ -> Map.get(config, :mode)
    end
  end

  def mode(%{mode: mode}), do: mode
  def mode(_other), do: nil

  @doc false
  def module_for(%__MODULE__{provider: provider}), do: module_for(provider)
  def module_for(:local), do: {:ok, CIA.Sandbox.Local}
  def module_for(:sprite), do: {:ok, CIA.Sandbox.Sprite}
  def module_for(:sprites), do: {:ok, CIA.Sandbox.Sprite}
  def module_for(%module{}), do: {:ok, module}
  def module_for(module) when is_atom(module), do: {:ok, module}
  def module_for(other), do: {:error, {:invalid_sandbox, other}}

  defp normalize_watch_paths(path) when is_binary(path), do: [path]
  defp normalize_watch_paths(paths) when is_list(paths), do: paths

  defp delegate_sandbox_op(%__MODULE__{runtime: nil}, op, _args)
       when op not in [:start, :stop] do
    {:error, {:sandbox_not_started, op}}
  end

  defp delegate_sandbox_op(%__MODULE__{runtime: runtime} = sandbox, op, args)
       when not is_nil(runtime) and is_atom(op) and is_list(args) do
    with {:ok, module} <- module_for(sandbox),
         true <- function_exported?(module, op, length(args) + 1) do
      apply(module, op, [runtime | args])
    else
      false -> {:error, {:unsupported_sandbox_operation, op}}
      {:error, _reason} = error -> error
    end
  end

  defp delegate_sandbox_op(sandbox, op, args) when is_atom(op) and is_list(args) do
    with {:ok, module} <- module_for(sandbox),
         true <- function_exported?(module, op, length(args) + 1) do
      apply(module, op, [sandbox | args])
    else
      false -> {:error, {:unsupported_sandbox_operation, op}}
      {:error, _reason} = error -> error
    end
  end

  defp normalize_config(config, provider) when is_map(config) do
    with {:ok, module} <- module_for(provider) do
      case Code.ensure_loaded(module) do
        {:module, _module} ->
          case function_exported?(module, :normalize_config, 1) do
            true -> module.normalize_config(config)
            false -> {:ok, config}
          end

        {:error, _reason} ->
          {:ok, config}
      end
    end
  end

  defp validate_id(id) when is_binary(id) and byte_size(id) > 0, do: {:ok, id}
  defp validate_id(_), do: {:error, {:invalid_id, :expected_non_empty_string}}

  defp validate_provider(nil), do: {:error, {:missing_option, :provider}}
  defp validate_provider(provider) when is_atom(provider), do: {:ok, provider}
  defp validate_provider(_), do: {:error, {:missing_option, :provider}}

  defp validate_metadata(metadata) when is_map(metadata), do: {:ok, metadata}
  defp validate_metadata(_), do: {:error, {:invalid_metadata, :expected_map}}
end
