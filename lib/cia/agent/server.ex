defmodule CIA.Agent.Server do
  @moduledoc false

  use GenServer

  defstruct [:state, subscribers: %{}]

  alias CIA.Agent
  alias CIA.Agent.State
  alias CIA.Harness
  alias CIA.Sandbox
  alias CIA.Thread
  alias CIA.Turn
  alias CIA.Workspace

  @doc false
  def start_link(opts) when is_list(opts) do
    {agent_opts, server_opts} =
      Keyword.split(opts, [
        :id,
        :harness,
        :sandbox,
        :status,
        :provider_ref,
        :metadata,
        :auth,
        :hooks,
        :workspace,
        :env
      ])

    with {:ok, %State{} = state} <- State.new(agent_opts) do
      GenServer.start_link(__MODULE__, state, server_opts)
    end
  end

  @doc false
  def agent(server), do: GenServer.call(server, :agent)

  @doc false
  def subscribe(server, subscriber \\ self(), opts \\ [])
      when is_pid(subscriber) and is_list(opts) do
    GenServer.call(server, {:subscribe, subscriber, opts})
  end

  @doc false
  def turn(server, turn_or_id), do: GenServer.call(server, {:turn, turn_id(turn_or_id)})

  @doc false
  def set_status(server, status), do: GenServer.call(server, {:set_status, status})

  @doc false
  def start_thread(server, opts \\ []), do: GenServer.call(server, {:start_thread, opts})

  @doc false
  def submit_turn(server, thread_or_id, input, opts \\ []),
    do: GenServer.call(server, {:submit_turn, thread_or_id, input, opts})

  @doc false
  def steer_turn(server, turn_or_id, input, opts \\ []),
    do: GenServer.call(server, {:steer_turn, turn_or_id, input, opts})

  @doc false
  def cancel_turn(server, turn_or_id), do: GenServer.call(server, {:cancel_turn, turn_or_id})

  @doc false
  def resolve(server, request_id, decision),
    do: GenServer.call(server, {:resolve, request_id, decision})

  @doc false
  def stop(server, timeout \\ :infinity), do: GenServer.stop(server, :normal, timeout)

  @impl true
  def init(%State{} = state) do
    state = put_agent_pid(state, self())

    with {:ok, started_state} <- start_runtime(state),
         {:ok, running_state} <- State.put_agent_status(started_state, :running) do
      final_state =
        run_after_hooks(
          running_state,
          :after_start,
          %{result: {:ok, running_state.agent}}
        )

      {:ok, %__MODULE__{state: final_state}}
    else
      {:error, %State{} = failed_state, reason} = error ->
        _ =
          run_after_hooks(
            failed_state,
            :after_start,
            %{result: error}
          )

        {:stop, reason}
    end
  end

  @impl true
  def handle_call(
        :agent,
        _from,
        %__MODULE__{state: %State{agent: %Agent{} = agent}} = server_state
      ) do
    {:reply, agent, server_state}
  end

  def handle_call({:subscribe, subscriber, opts}, _from, %__MODULE__{} = server_state) do
    with {:ok, events} <- validate_subscription_events(Keyword.get(opts, :events, :all)) do
      {:reply, :ok, add_subscriber(server_state, subscriber, events)}
    else
      {:error, _reason} = error -> {:reply, error, server_state}
    end
  end

  def handle_call({:turn, id}, _from, %__MODULE__{state: %State{} = state} = server_state) do
    {:reply, State.get_turn(state, id), server_state}
  end

  def handle_call(
        {:set_status, status},
        _from,
        %__MODULE__{state: %State{} = state} = server_state
      ) do
    case State.put_agent_status(state, status) do
      {:ok, %State{agent: %Agent{} = agent} = updated_state} ->
        {:reply, {:ok, agent}, put_state(server_state, updated_state)}

      {:error, {:invalid_status, _} = reason} ->
        {:reply, {:error, reason}, server_state}
    end
  end

  def handle_call(
        {:start_thread, opts},
        _from,
        %__MODULE__{state: %State{} = state} = server_state
      ) do
    with {:ok, thread_ref} <- Harness.start_thread(state.harness, opts) do
      thread =
        Thread.new(
          id: thread_ref.id,
          agent_id: state.agent.id,
          provider_ref: thread_ref,
          status: :active,
          metadata: Keyword.get(opts, :metadata, %{})
        )

      updated_state = State.put_thread(state, thread)

      updated_server_state =
        server_state
        |> put_state(updated_state)
        |> broadcast_event(:thread, {:thread, :started, %{thread_id: thread.id}})

      {:reply, {:ok, thread}, updated_server_state}
    else
      {:error, _reason} = error -> {:reply, error, server_state}
    end
  end

  def handle_call(
        {:submit_turn, thread_or_id, input, opts},
        _from,
        %__MODULE__{state: %State{} = state} = server_state
      ) do
    opts = maybe_put_default_sandbox_policy(opts, state)

    with {:ok, %Thread{} = thread} <- resolve_thread(state, thread_or_id),
         {:ok, turn_ref} <- Harness.submit_turn(state.harness, thread.provider_ref, input, opts) do
      updated_thread = %Thread{thread | status: :busy}

      turn =
        Turn.new(
          id: turn_ref.id,
          thread_id: updated_thread.id,
          provider_ref: turn_ref,
          status: :running,
          metadata: Keyword.get(opts, :metadata, %{})
        )

      updated_state =
        state
        |> State.put_thread(updated_thread)
        |> State.put_turn(turn)

      updated_server_state =
        server_state
        |> put_state(updated_state)
        |> broadcast_event(
          :turn,
          {:turn, :started, %{thread_id: turn.thread_id, turn_id: turn.id}}
        )

      {:reply, {:ok, turn}, updated_server_state}
    else
      {:error, _reason} = error -> {:reply, error, server_state}
    end
  end

  def handle_call(
        {:steer_turn, turn_or_id, input, opts},
        _from,
        %__MODULE__{state: %State{} = state} = server_state
      ) do
    with {:ok, turn} <- resolve_turn(state, turn_or_id),
         :ok <- Harness.steer_turn(state.harness, turn.provider_ref, input, opts) do
      {:reply, :ok, server_state}
    else
      {:error, _reason} = error -> {:reply, error, server_state}
    end
  end

  def handle_call(
        {:cancel_turn, turn_or_id},
        _from,
        %__MODULE__{state: %State{} = state} = server_state
      ) do
    with {:ok, %Turn{} = turn} <- resolve_turn(state, turn_or_id),
         :ok <- Harness.cancel_turn(state.harness, turn.provider_ref),
         {:ok, updated_state, updated_turn} <-
           State.update_turn_status(state, turn.id, :cancelled),
         {:ok, %Thread{} = thread} <- State.get_thread(updated_state, turn.thread_id) do
      final_state = State.put_thread(updated_state, %Thread{thread | status: :active})
      event_payload = %{thread_id: turn.thread_id, turn_id: updated_turn.id, status: :cancelled}

      updated_server_state =
        server_state
        |> put_state(final_state)
        |> broadcast_event(:turn, {:turn, :status, event_payload})

      {:reply, {:ok, updated_turn}, updated_server_state}
    else
      {:error, _reason} = error -> {:reply, error, server_state}
    end
  end

  def handle_call(
        {:resolve, request_id, decision},
        _from,
        %__MODULE__{state: %State{} = state} = server_state
      ) do
    case Harness.resolve(state.harness, request_id, decision) do
      :ok -> {:reply, :ok, server_state}
      {:error, _reason} = error -> {:reply, error, server_state}
    end
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, pid, _reason}, %__MODULE__{} = server_state) do
    {:noreply, unsubscribe(server_state, pid)}
  end

  def handle_info({:cia_harness, harness, payload}, %__MODULE__{} = server_state) do
    updated_server_state =
      server_state
      |> maybe_broadcast_normalized_harness_event(harness, payload)
      |> broadcast_event(:raw, {:harness, harness, payload})

    {:noreply, updated_server_state}
  end

  def handle_info({:cia_sandbox_watch, watch_id, payload}, %__MODULE__{} = server_state) do
    updated_server_state =
      broadcast_event(server_state, :sandbox, {:sandbox, :watch, watch_id, payload})

    {:noreply, updated_server_state}
  end

  def handle_info(_message, %__MODULE__{} = server_state) do
    {:noreply, server_state}
  end

  @impl true
  def terminate(
        reason,
        %__MODULE__{state: %State{} = state}
      ) do
    state =
      case run_before_hooks(state, :before_stop, %{reason: reason}) do
        {:ok, %State{} = updated_state} -> updated_state
        {:error, _reason} -> state
      end

    %State{sandbox: sandbox, workspace: workspace, harness: harness} = state

    if harness != nil and harness.session != %{} do
      _ = Harness.stop_session(harness)
    end

    if workspace != nil and sandbox != nil do
      _ = Workspace.cleanup(workspace, sandbox)
    end

    if sandbox != nil do
      _ = Sandbox.stop(sandbox)
    end

    _ =
      run_after_hooks(
        state,
        :after_stop,
        %{reason: reason, result: :ok}
      )

    :ok
  end

  defp start_runtime(%State{} = state) do
    with {:ok, command} <- Harness.runtime_command(state),
         {:ok, sandbox} <- Sandbox.start(state.sandbox, command: command, env: state.env) do
      sandbox_state = State.put_sandbox(state, sandbox)

      with {:ok, sandbox_state} <- run_before_hooks(sandbox_state, :before_start, %{}),
           {:ok, workspace} <- Workspace.materialize(state.workspace, sandbox) do
        runtime_state = State.put_workspace(sandbox_state, workspace)

        case Harness.start_session(runtime_state) do
          {:ok, harness, _events} ->
            {:ok, State.put_harness(runtime_state, harness)}

          {:error, reason} ->
            failed_state = put_agent_status(runtime_state, :failed)
            cleanup_runtime(failed_state)
            {:error, failed_state, reason}
        end
      else
        {:error, reason} ->
          failed_state = put_agent_status(sandbox_state, :failed)
          cleanup_runtime(failed_state)
          {:error, failed_state, reason}
      end
    else
      {:error, reason} ->
        failed_state = put_agent_status(state, :failed)
        {:error, failed_state, reason}
    end
  end

  defp resolve_thread(%State{} = state, thread_or_id) do
    State.get_thread(state, thread_id(thread_or_id))
  end

  defp resolve_turn(%State{} = state, turn_or_id) do
    State.get_turn(state, turn_id(turn_or_id))
  end

  defp thread_id(%Thread{id: id}), do: id
  defp thread_id(id) when is_binary(id), do: id

  defp turn_id(%Turn{id: id}), do: id
  defp turn_id(id) when is_binary(id), do: id

  defp run_before_hooks(%State{} = state, hook_name, context) when is_atom(hook_name) do
    state.hooks
    |> Map.get(hook_name, [])
    |> Enum.with_index(1)
    |> Enum.reduce_while({:ok, state}, fn {hook, index}, {:ok, state} ->
      case invoke_hook(hook, hook_context(state, context)) do
        :ok ->
          {:cont, {:ok, state}}

        {:ok, hook_state} ->
          {:cont, {:ok, State.put_hook_state(state, hook_state)}}

        {:error, reason} ->
          {:halt, {:error, normalize_before_hook_error(hook_name, index, reason)}}
      end
    end)
  end

  defp run_after_hooks(%State{} = state, hook_name, context) when is_atom(hook_name) do
    state.hooks
    |> Map.get(hook_name, [])
    |> Enum.with_index(1)
    |> Enum.reduce(state, fn {hook, _index}, state ->
      case invoke_hook(hook, hook_context(state, context)) do
        :ok ->
          state

        {:ok, hook_state} ->
          State.put_hook_state(state, hook_state)

        {:error, _reason} ->
          state
      end
    end)
  end

  defp hook_context(%State{} = state, extra) when is_map(extra) do
    Map.merge(
      %{
        agent: state.agent,
        harness: state.harness,
        sandbox: state.sandbox,
        workspace: state.workspace,
        env: state.env,
        state: state.state
      },
      extra
    )
  end

  defp invoke_hook(hook, context) when is_function(hook, 1) and is_map(context) do
    try do
      case hook.(context) do
        :ok -> :ok
        {:ok, hook_state} when is_map(hook_state) -> {:ok, hook_state}
        other -> {:error, {:invalid_return, other}}
      end
    rescue
      error -> {:error, {:exception, error, __STACKTRACE__}}
    catch
      kind, reason -> {:error, {:throw, kind, reason}}
    end
  end

  defp normalize_before_hook_error(hook_name, index, {:invalid_return, other}) do
    {:hook_failed, hook_name, index, other}
  end

  defp normalize_before_hook_error(hook_name, index, {:exception, error, stacktrace}) do
    {:hook_exception, hook_name, index, error, stacktrace}
  end

  defp normalize_before_hook_error(hook_name, index, {:throw, kind, reason}) do
    {:hook_throw, hook_name, index, kind, reason}
  end

  defp put_agent_pid(%State{agent: %Agent{} = agent} = state, pid) when is_pid(pid) do
    %State{state | agent: %Agent{agent | pid: pid}}
  end

  defp put_agent_status(%State{} = state, status) do
    case State.put_agent_status(state, status) do
      {:ok, updated_state} -> updated_state
      {:error, _reason} -> state
    end
  end

  defp cleanup_runtime(%State{workspace: workspace, sandbox: sandbox}) do
    if workspace != nil and sandbox != nil do
      _ = Workspace.cleanup(workspace, sandbox)
    end

    if sandbox != nil do
      _ = Sandbox.stop(sandbox)
    end

    :ok
  end

  defp maybe_put_default_sandbox_policy(opts, state) when is_list(opts) do
    case Keyword.has_key?(opts, :sandbox_policy) do
      true ->
        opts

      false ->
        case sandbox_policy(state) do
          nil -> opts
          policy -> Keyword.put(opts, :sandbox_policy, policy)
        end
    end
  end

  defp sandbox_policy(%State{sandbox: sandbox, workspace: %{root: root}})
       when is_binary(root) do
    case Sandbox.mode(sandbox) do
      mode when mode in [:workspace_write, "workspace-write", "workspaceWrite"] ->
        %{
          "type" => "workspaceWrite",
          "writableRoots" => [root],
          "networkAccess" => false,
          "excludeTmpdirEnvVar" => false,
          "excludeSlashTmp" => false
        }

      _ ->
        sandbox_policy(%State{sandbox: sandbox})
    end
  end

  defp sandbox_policy(%State{sandbox: sandbox}) do
    case Sandbox.mode(sandbox) do
      mode when mode in [:read_only, "read-only", "readOnly"] ->
        %{"type" => "readOnly", "networkAccess" => false}

      mode
      when mode in [:danger_full_access, :full_access, "danger-full-access", "dangerFullAccess"] ->
        %{"type" => "dangerFullAccess", "networkAccess" => false}

      _ ->
        nil
    end
  end

  defp sandbox_policy(_), do: nil

  defp put_state(%__MODULE__{} = server_state, %State{} = state) do
    %__MODULE__{server_state | state: state}
  end

  defp add_subscriber(%__MODULE__{subscribers: subscribers} = server_state, pid, events)
       when is_pid(pid) do
    case Map.get(subscribers, pid) do
      %{ref: ref} ->
        %__MODULE__{
          server_state
          | subscribers: Map.put(subscribers, pid, %{ref: ref, events: events})
        }

      nil ->
        %__MODULE__{
          server_state
          | subscribers: Map.put(subscribers, pid, %{ref: Process.monitor(pid), events: events})
        }
    end
  end

  defp unsubscribe(%__MODULE__{subscribers: subscribers} = server_state, pid) when is_pid(pid) do
    case Map.pop(subscribers, pid) do
      {nil, _subscribers} ->
        server_state

      {%{ref: ref}, subscribers} ->
        Process.demonitor(ref, [:flush])
        %__MODULE__{server_state | subscribers: subscribers}
    end
  end

  defp broadcast_event(
         %__MODULE__{state: %State{agent: %Agent{} = agent}, subscribers: subscribers} =
           server_state,
         category,
         event
       ) do
    Enum.each(subscribers, fn {subscriber, %{events: events}} ->
      if subscribed_to_event?(events, category) do
        send(subscriber, {:cia, agent, event})
      end
    end)

    server_state
  end

  defp maybe_broadcast_normalized_harness_event(
         %__MODULE__{} = server_state,
         harness,
         {:server_request, request}
       ) do
    case normalize_request_event(harness, request) do
      {:ok, event} -> broadcast_event(server_state, :request, event)
      :ignore -> server_state
    end
  end

  defp maybe_broadcast_normalized_harness_event(
         %__MODULE__{} = server_state,
         harness,
         {:server_message, message}
       ) do
    server_state
    |> maybe_update_from_harness_notification(harness, message)
    |> then(fn updated_server_state ->
      case normalize_notification_event(harness, message) do
        {:ok, category, event} -> broadcast_event(updated_server_state, category, event)
        :ignore -> updated_server_state
      end
    end)
  end

  defp maybe_broadcast_normalized_harness_event(%__MODULE__{} = server_state, _harness, _payload),
    do: server_state

  defp maybe_update_from_harness_notification(
         %__MODULE__{state: %State{} = state} = server_state,
         :codex,
         %{method: "turn/updated", params: %{"turnId" => turn_id} = params}
       ) do
    status = normalize_turn_status(Map.get(params, "status"))

    updated_state =
      case status do
        nil ->
          state

        status ->
          with {:ok, state, _turn} <- State.update_turn_status(state, turn_id, status) do
            state
          else
            _ -> state
          end
      end

    put_state(server_state, updated_state)
  end

  defp maybe_update_from_harness_notification(
         %__MODULE__{state: %State{} = state} = server_state,
         :codex,
         %{method: "turn/completed", params: %{"turnId" => turn_id}}
       ) do
    updated_state =
      case State.update_turn_status(state, turn_id, :completed) do
        {:ok, updated_state, _turn} -> updated_state
        _ -> state
      end

    put_state(server_state, updated_state)
  end

  defp maybe_update_from_harness_notification(
         %__MODULE__{state: %State{} = state} = server_state,
         :codex,
         %{method: method, params: %{"turnId" => turn_id}}
       )
       when method in ["turn/interrupted", "turn/cancelled", "turn/failed"] do
    status =
      case method do
        "turn/interrupted" -> :interrupted
        "turn/cancelled" -> :cancelled
        "turn/failed" -> :failed
      end

    updated_state =
      case State.update_turn_status(state, turn_id, status) do
        {:ok, updated_state, _turn} -> updated_state
        _ -> state
      end

    put_state(server_state, updated_state)
  end

  defp maybe_update_from_harness_notification(%__MODULE__{} = server_state, _harness, _message),
    do: server_state

  defp normalize_request_event(
         :codex,
         %{id: request_id, method: "item/commandExecution/requestApproval", params: params}
       ) do
    {:ok,
     {:request, :approval,
      %{
        id: request_id,
        kind: :command,
        thread_id: Map.get(params, "threadId"),
        turn_id: Map.get(params, "turnId"),
        item_id: Map.get(params, "itemId"),
        reason: Map.get(params, "reason"),
        command: Map.get(params, "command"),
        cwd: Map.get(params, "cwd"),
        available_decisions: normalize_available_decisions(Map.get(params, "availableDecisions"))
      }}}
  end

  defp normalize_request_event(
         :codex,
         %{id: request_id, method: "item/fileChange/requestApproval", params: params}
       ) do
    {:ok,
     {:request, :approval,
      %{
        id: request_id,
        kind: :file_change,
        thread_id: Map.get(params, "threadId"),
        turn_id: Map.get(params, "turnId"),
        item_id: Map.get(params, "itemId"),
        reason: Map.get(params, "reason"),
        grant_root: Map.get(params, "grantRoot"),
        available_decisions: normalize_available_decisions(Map.get(params, "availableDecisions"))
      }}}
  end

  defp normalize_request_event(
         :codex,
         %{id: request_id, method: method, params: params}
       )
       when method in ["tool/requestUserInput", "item/tool/requestUserInput"] do
    {:ok,
     {:request, :user_input,
      %{
        id: request_id,
        thread_id: Map.get(params, "threadId"),
        turn_id: Map.get(params, "turnId"),
        item_id: Map.get(params, "itemId"),
        prompt: Map.get(params, "prompt"),
        questions: Map.get(params, "questions", [])
      }}}
  end

  defp normalize_request_event(_harness, _request), do: :ignore

  defp normalize_notification_event(
         :codex,
         %{method: "serverRequest/resolved", params: params}
       ) do
    {:ok, :request,
     {:request, :resolved,
      %{
        id: Map.get(params, "requestId"),
        thread_id: Map.get(params, "threadId")
      }}}
  end

  defp normalize_notification_event(
         :codex,
         %{method: "thread/started", params: %{"threadId" => thread_id} = params}
       ) do
    {:ok, :thread, {:thread, :started, %{thread_id: thread_id, name: Map.get(params, "name")}}}
  end

  defp normalize_notification_event(
         :codex,
         %{
           method: "thread/status/changed",
           params: %{"threadId" => thread_id, "status" => status}
         }
       ) do
    {:ok, :thread,
     {:thread, :status, %{thread_id: thread_id, status: normalize_thread_status(status)}}}
  end

  defp normalize_notification_event(
         :codex,
         %{method: method, params: %{"threadId" => thread_id}}
       )
       when method in ["thread/archived", "thread/unarchived", "thread/closed"] do
    event_name =
      case method do
        "thread/archived" -> :archived
        "thread/unarchived" -> :unarchived
        "thread/closed" -> :closed
      end

    {:ok, :thread, {:thread, event_name, %{thread_id: thread_id}}}
  end

  defp normalize_notification_event(
         :codex,
         %{method: "turn/updated", params: %{"turnId" => turn_id} = params}
       ) do
    {:ok, :turn,
     {:turn, :status,
      %{
        thread_id: Map.get(params, "threadId"),
        turn_id: turn_id,
        status: normalize_turn_status(Map.get(params, "status"))
      }}}
  end

  defp normalize_notification_event(
         :codex,
         %{method: method, params: %{"turnId" => turn_id} = params}
       )
       when method in [
              "turn/started",
              "turn/completed",
              "turn/interrupted",
              "turn/cancelled",
              "turn/failed"
            ] do
    event_name =
      case method do
        "turn/started" -> :started
        "turn/completed" -> :completed
        "turn/interrupted" -> :interrupted
        "turn/cancelled" -> :cancelled
        "turn/failed" -> :failed
      end

    {:ok, :turn, {:turn, event_name, %{thread_id: Map.get(params, "threadId"), turn_id: turn_id}}}
  end

  defp normalize_notification_event(_harness, _message), do: :ignore

  defp validate_subscription_events(:all), do: {:ok, :all}

  defp validate_subscription_events(events) when is_list(events) do
    case Enum.all?(events, &(&1 in [:agent, :thread, :turn, :request, :sandbox, :raw])) do
      true -> {:ok, MapSet.new(events)}
      false -> {:error, {:invalid_subscription_events, events}}
    end
  end

  defp validate_subscription_events(other),
    do: {:error, {:invalid_subscription_events, other}}

  defp subscribed_to_event?(:all, _category), do: true
  defp subscribed_to_event?(%MapSet{} = events, category), do: MapSet.member?(events, category)

  defp normalize_available_decisions(nil) do
    [:approve, :approve_for_session, :deny, :cancel]
  end

  defp normalize_available_decisions(decisions) when is_list(decisions) do
    Enum.map(decisions, fn
      "accept" -> :approve
      "acceptForSession" -> :approve_for_session
      "decline" -> :deny
      "cancel" -> :cancel
      other -> other
    end)
  end

  @expected_status ["running", "completed", "cancelled", "interrupted", "failed"]

  defp normalize_thread_status(status), do: status

  defp normalize_turn_status(status) when is_binary(status) do
    with status when status in @expected_status <- status do
      String.to_existing_atom(status)
    end
  end

  defp normalize_turn_status(status), do: status
end
