defmodule CIA do
  @moduledoc """
  The CIA (Central Intelligence Agent) is an opinionated library for managing
  background agents from an Elixir app.

  CIA takes the position that a background agent always consists of:

    * the sandbox: where that agent is running
    * the workspace: what filesystem scope that work should happen in
    * the harness: what agent implementation is running

  And can be interacted with by managing threads and turns.

  ## Getting Started

  To create an agent, you must configure a sandbox, a workspace, and a harness:

      key = System.fetch_env!("OPENAI_API_KEY")

      config =
        CIA.new()
        |> CIA.sandbox(:local)
        |> CIA.workspace(:directory, root: "/tmp/cia-demo")
        |> CIA.harness(:codex, auth: {:api_key, key})

  Configurations are data-only until the agent is actually started:

      {:ok, agent} = CIA.start(plan)

  After an agent has been started, you can create threads and submit turns:

      {:ok, thread} = CIA.thread(agent, cwd: "/tmp/cia-demo")
      {:ok, _turn} = CIA.turn(agent, thread, "Create a README that explains the project.")

  ## Managing Sandbox and Workspace Lifecycles

  CIA treats sandbox and workspace management as explicit concerns instead of
  implicitly tying them to the agent.

  In practice, CIA supports 3 lifecycle modes for both sandboxes and workspaces:

    * `:ephemeral` - sandbox or workspace is created and destroyed with the agent
    * `:durable` - sandbox or workspace is created, but persists after the agent dies
    * `:attached` - sandboxes or workspace is assumed to exist before the agent starts
      and after the agent dies

  ## Using Lifecycle Hooks

  It is common to want to perform some setup work before starting an agent. CIA
  exposes lifecycle hooks which you can use to perform setup work, start filesystem
  watches, or checkpoint sandbox state after some work has been done:

      plan =
        CIA.new()
        |> CIA.sandbox(:local, lifecycle: :ephemeral)
        |> CIA.workspace(:directory, root: "/tmp/cia-demo")
        |> CIA.before_start(fn %{sandbox: sandbox} ->
          with {_, 0} <- CIA.Sandbox.cmd(sandbox, "mkdir", ["-p", "/tmp/cia-demo"]) do
            :ok
          end
        end)

  Supported hooks are `before_start`, `after_start`, `before_stop`, `after_stop`.
  These hooks are relative to the *harness process*, meaning they always run after
  the sandbox and workspace have been initialized.

  Hooks forward user-managed state if returned from within the hook:

      plan =
        CIA.new()
        |> CIA.sandbox(:local)
        |> CIA.workspace(:directory)
        |> CIA.before_start(fn %{sandbox: sandbox, state: state} ->
          tmpdir = "/tmp/dir_#{System.unique_integer([:positive, :monotonic])}"

          with {_, 0} <- CIA.Sandbox.cmd(sandbox, "mkdir", ["-p", tmpdir]) do
            {:ok, Map.put(state, :tmpdir, tmpdir)}
          end
        end)
        |> CIA.before_stop(fn %{state: %{tmpdir: tmpdir}} ->
          with {_, 0} <- CIA.Sandbox.cmd(sandbox, "rm", ["-rf", tmpdir]) do
            :ok
          end
        end)

  ## Streaming Agent Events

  CIA allows you to subscribe to event streams emitted by running agents.
  These event streams consist of normalized events for thread lifecycle, turn
  lifecycle, sandbox watch activity, and interactive harness requests. Raw
  harness events are also available for adapter-specific integrations.

  Events have the following shape:

      {:cia, agent, event}

  You can subscribe to all or a filtered subset of agent events:

      :ok = CIA.subscribe(agent, self(), events: [:thread, :turn, :request, :raw])

      receive do
        {:cia, ^agent, {:turn, :started, %{turn_id: turn_id}}} ->
          IO.puts("turn started: \#{turn_id}")

        {:cia, ^agent, {:request, :approval, request}} ->
          IO.inspect(request, label: "approval needed")

        {:cia, ^agent, {:harness, :codex, payload}} ->
          IO.inspect(payload, label: "raw codex event")
      end

  If you subscribe to events within an agent lifecycle hook, they are owned and forwarded
  through the managing agent process by default. For example, if you start a sandbox
  filesystem watch inside `before_start`, you will receive those messages through an
  agent subscription:

      plan =
        CIA.new()
        |> CIA.sandbox(:local)
        |> CIA.workspace(:directory, root: "/tmp/cia-demo")
        |> CIA.before_start(fn %{sandbox: sandbox} ->
          case CIA.Sandbox.watch(sandbox, ["/tmp/cia-demo"], recursive: true) do
            {:ok, _watch} -> :ok
            {:error, reason} -> {:error, reason}
          end
        end)
        |> CIA.harness(:codex, auth: {:api_key, key})

      {:ok, agent} = CIA.start(plan)
      :ok = CIA.subscribe(agent, self(), events: [:sandbox])

  Once that watch exists, CIA forwards sandbox watch activity as normalized
  agent events:

      receive do
        {:cia, ^agent, {:sandbox, :watch, watch_id, :ready}} ->
          IO.puts("sandbox watch ready: \#{watch_id}")

        {:cia, ^agent, {:sandbox, :watch, watch_id, {:event, %{type: :write, path: path}}}} ->
          IO.puts("sandbox watch \#{watch_id}: wrote \#{path}")
      end

  ## Resolving Input Requests

  Some harness actions are interactive. For example, a harness may ask for
  approval before running a command or ask for additional user input while a
  turn is in progress.

  CIA normalizes those requests into events and lets the application answer
  them with `resolve/3`.

      receive do
        {:cia, ^agent, {:request, :approval, %{id: request_id}}} ->
          :ok = CIA.resolve(agent, request_id, :approve_for_session)

        {:cia, ^agent, {:request, :user_input, %{id: request_id}}} ->
          :ok = CIA.resolve(agent, request_id, {:input, "Continue with the migration."})
      end

  The caller can log, audit, defer, or deny requests without needing direct access
  to harness-specific transport details.

  ## Customizing a Harness

  Basic harness configuration happens via `CIA.harness/3`. CIA also supports more
  involved customizations:

    * `CIA.mcp/3` - configure/attach MCPs to the agent harness
    * `CIA.tool/2` - configure tool-policies for the agent harness

  For example, you can configure custom MCPs in this way:

      plan =
        CIA.new()
        |> CIA.harness(:codex, auth: {:api_key, key})
        |> CIA.mcp(:docs,
          transport: :http,
          url: "https://mcp.example.com",
          headers: %{"Authorization" => "Bearer ..."}
        )

  And configure custom tool policies:

      CIA.tool(plan, allow: [{:mcp, :docs, :all}], approval: :never)

  ## Extending CIA

  CIA is designed to normalize the core runtime model while still allowing
  application-specific providers and harness adapters via:

    * custom sandbox providers implementing `CIA.Sandbox`
    * custom harness adapters implementing `CIA.Harness`
    * custom workspace adapters implementing `CIA.Workspace`
  """

  alias CIA.{Agent, Plan, Sandbox, Thread, Workspace}
  alias CIA.Agent.Server

  @hook_names [:before_start, :after_start, :before_stop, :after_stop]

  @doc """
  Creates a new CIA agent configuration.

  Agents are data-only "plans" until started with `CIA.start/2`.
  """
  def new do
    Plan.new()
  end

  @doc """
  Configures the given plan to use a sandbox with the given `provider`.

  Provider must be one of the supported "shortcut" atoms:

    * `:local` - to simply use the local machine
    * `:sprite` - to use a [Sprite](https://sprites.dev)

  Or a module which implements the `CIA.Sandbox` behaviour.

  ## Options

    * `:name` - the name of the sandbox, typically handled by the provider.

    * `:lifecycle` - the lifecycle of the sandbox that the running agent
      is attached to. One of `:ephemeral`, `:durable`, or `:attached`.
      See [Sandbox Lifecycles](#) for more information.

  All other options are forwared to the provider, and should be assumed to
  be provider-specific.
  """
  def sandbox(%Plan{} = plan, provider, opts \\ [])
      when is_atom(provider) and is_list(opts) do
    Plan.put_sandbox(plan, Keyword.put(opts, :provider, provider))
  end

  @doc """
  Adds workspace configuration to a pipeable CIA configuration.

  The first argument selects the workspace kind. All remaining
  workspace configuration belongs here, including root paths,
  names, and identifiers.
  """
  def workspace(%Plan{} = plan, kind, opts \\ [])
      when is_atom(kind) and is_list(opts) do
    Plan.put_workspace(plan, Keyword.put(opts, :kind, kind))
  end

  @doc """
  Adds an agent lifecycle hook to a pipeable CIA configuration.

  Supported hook names are:

  - `:before_start`
  - `:after_start`
  - `:before_stop`
  - `:after_stop`

  Hook callbacks are unary functions that receive a context map. Hooks may
  return either `:ok` or `{:ok, state}` where `state` is a user-defined map
  persisted for the lifetime of the agent and threaded through later hook
  contexts. Invalid return values from `before_*` hooks abort that agent
  operation. `after_*` hooks are observational and receive the final `:result`
  for the attempted operation.

  These hooks are agent-scoped. `before_start/2` and `after_start/2` are
  relative to the CIA agent lifecycle, not sandbox lifecycle. `before_start/2`
  receives the live sandbox runtime because sandbox provisioning happens before
  the agent is considered started. Hook contexts also include the current
  user-defined `:state` map.
  """
  def hook(%Plan{} = plan, hook_name, fun) when is_atom(hook_name) and is_function(fun, 1) do
    Plan.put_hook(plan, hook_name, fun)
  end

  for hook_name <- @hook_names do
    @doc "Adds a `#{hook_name}` agent lifecycle hook to a pipeable CIA configuration."
    def unquote(hook_name)(%Plan{} = plan, fun) when is_function(fun, 1) do
      hook(plan, unquote(hook_name), fun)
    end
  end

  @doc """
  Adds harness configuration to a pipeable CIA configuration.

  The first argument selects the harness implementation. This configuration is
  stored on the returned builder state and does not start a live agent on its
  own. All remaining harness configuration belongs here,
  including harness, auth, instructions, names, and identifiers.
  """
  def harness(%Plan{} = plan, harness, opts \\ [])
      when is_atom(harness) and is_list(opts) do
    Plan.put_harness(plan, Keyword.put(opts, :harness, harness))
  end

  @doc """
  Adds an MCP server declaration to the plan.

  `CIA.mcp/3` is additive and upserts by server id. MCP declarations may appear
  before or after `CIA.harness/3`. Once a harness is configured, CIA compiles
  the accumulated MCP declarations into the runtime harness configuration.
  """
  def mcp(%Plan{} = plan, id, opts \\ [])
      when (is_atom(id) or is_binary(id)) and is_list(opts) do
    Plan.put_mcp(plan, id, opts)
  end

  @doc """
  Adds normalized tool policy to the plan.

  Multiple `tool/2` calls accumulate allow/deny rules. Singleton values such as
  approval policy use the last declared value. Tool policy may be declared
  before or after `CIA.harness/3`; CIA compiles the accumulated policy into the
  runtime harness configuration.
  """
  def tool(%Plan{} = plan, opts) when is_list(opts) do
    Plan.put_tool(plan, opts)
  end

  @doc """
  Starts a managed agent process.

  The returned handle is a `%CIA.Agent{}`. `start/1` consumes configuration
  built with the pipeable `sandbox/3`, `workspace/3`, and `harness/3` helpers.
  Configuration belongs on that builder. `start/1` executes it.

  By default, the agent process is started directly. To start it under your own
  supervisor, pass `supervisor: MyApp.CIAAgentSupervisor`.
  """
  def start(%Plan{} = plan, opts \\ []) when is_list(opts) do
    with {:ok, start_opts} <- plan_start_opts(plan),
         {:ok, pid} <- start_agent(start_opts, Keyword.get(opts, :supervisor)) do
      {:ok, Server.agent(pid)}
    end
  end

  defp start_agent(opts, nil), do: Server.start_link(opts)

  defp start_agent(opts, supervisor),
    do: DynamicSupervisor.start_child(supervisor, {Server, opts})

  defp plan_start_opts(%Plan{} = plan) do
    with :ok <- validate_harness_config(plan.harness),
         {:ok, sandbox} <- plan_sandbox(plan),
         {:ok, workspace} <- plan_workspace(plan, sandbox) do
      {:ok,
       [
         harness: plan.harness,
         sandbox: sandbox,
         workspace: workspace,
         hooks: plan.hooks
       ]}
    end
  end

  @doc """
  Stops a managed agent process.

  Stopping an already-exited or unknown agent is treated as a successful no-op.

  Stopping an agent tears down the harness session and then asks the sandbox to
  clean up its runtime resources.
  """
  def stop(%Agent{pid: pid}, timeout \\ :infinity) do
    case pid do
      nil -> :ok
      pid -> Server.stop(pid, timeout)
    end
  end

  @doc """
  Subscribes a process to agent events.

  If no subscriber PID is provided, the calling process is subscribed.

  Subscribers receive messages in the form:

      {:cia, %CIA.Agent{}, event}

  CIA emits normalized events for requests, threads, turns, and sandbox watch
  activity, while still forwarding raw harness events for compatibility:

      {:cia, agent, {:request, :approval, payload}}
      {:cia, agent, {:request, :user_input, payload}}
      {:cia, agent, {:request, :resolved, payload}}
      {:cia, agent, {:thread, :started, payload}}
      {:cia, agent, {:turn, :status, payload}}
      {:cia, agent, {:sandbox, :watch, watch_id, payload}}

      {:cia, agent, {:harness, :codex, payload}}

  To scope delivery, pass `events: [...]` with any of:

  - `:thread`
  - `:turn`
  - `:request`
  - `:sandbox`
  - `:raw`

  Subscribers are monitored and automatically removed when the subscriber
  process exits.
  """
  def subscribe(%Agent{pid: pid}, subscriber \\ self(), opts \\ [])
      when is_pid(pid) and is_pid(subscriber) and is_list(opts) do
    Server.subscribe(pid, subscriber, opts)
  end

  @doc """
  Resolves a pending normalized harness request.

  Current normalized decisions are:

  - `:approve`
  - `:approve_for_session`
  - `:deny`
  - `:cancel`
  - `{:input, value}`
  """
  def resolve(%Agent{pid: pid}, request_id, decision) when is_pid(pid) do
    Server.resolve(pid, request_id, decision)
  end

  @doc """
  Creates a new thread on an agent.

  When creating a new thread with keyword options, the current supported keys
  are:

  - `:cwd`
  - `:model`
  - `:system_prompt`
  - `:metadata`

  `:metadata` is stored by CIA on the returned `%CIA.Thread{}`. The remaining
  options are currently forwarded to the active harness. `:system_prompt` is a
  thread-scoped inline override, distinct from harness-level `:instructions`
  configured through `CIA.harness/3`.
  """
  def thread(%Agent{pid: pid}, opts) when is_pid(pid) and is_list(opts) do
    Server.start_thread(pid, opts)
  end

  @doc """
  Submits a turn to a thread.

  The thread must be provided as a `%CIA.Thread{}` handle returned by CIA.

  The returned `%CIA.Turn{}` reflects CIA's local runtime view. In the current
  implementation, turns are marked `:running` when submitted and may later emit
  additional harness events through `subscribe/2`.
  """
  def turn(%Agent{pid: pid}, %Thread{} = thread, input, opts \\ [])
      when is_pid(pid) and is_list(opts) do
    Server.submit_turn(pid, thread, input, opts)
  end

  @doc """
  Sends additional input to a running turn.

  `turn_or_id` may be a `%CIA.Turn{}` or a known turn identifier.

  This is intended for live turn steering while the turn is still running.
  """
  def steer(%Agent{pid: pid}, turn_or_id, input, opts \\ []) when is_pid(pid) and is_list(opts) do
    Server.steer_turn(pid, turn_or_id, input, opts)
  end

  @doc """
  Cancels a running turn.

  `turn_or_id` may be a `%CIA.Turn{}` or a known turn identifier.

  On success, CIA updates its in-memory turn status to `:cancelled` and moves
  the owning thread back to `:active`.
  """
  def cancel(%Agent{pid: pid}, turn_or_id) when is_pid(pid) do
    Server.cancel_turn(pid, turn_or_id)
  end

  defp plan_sandbox(%Plan{sandbox: nil}), do: {:error, {:missing_option, :sandbox}}

  defp plan_sandbox(%Plan{sandbox: sandbox_config}) when is_map(sandbox_config) do
    sandbox_config
    |> Map.to_list()
    |> Sandbox.new()
  end

  defp plan_workspace(%Plan{workspace: nil}, _sandbox),
    do: {:error, {:missing_option, :workspace}}

  defp plan_workspace(%Plan{workspace: workspace_config}, %Sandbox{} = sandbox)
       when is_map(workspace_config) do
    workspace_config
    |> Map.to_list()
    |> then(&Workspace.new(sandbox, &1))
  end

  defp validate_harness_config(nil), do: :ok

  defp validate_harness_config(%CIA.Harness{config: config}) do
    if Map.has_key?(config, :cwd) or Map.has_key?(config, "cwd") do
      {:error, {:invalid_option, {:harness, :cwd}}}
    else
      :ok
    end
  end
end
