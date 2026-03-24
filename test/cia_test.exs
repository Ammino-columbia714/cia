defmodule CIATest do
  use ExUnit.Case, async: false

  alias CIA.Plan
  alias CIA.TestSupport.FakeCodexServer

  setup do
    trace_file = FakeCodexServer.trace_file("cia-fake-codex")

    on_exit(fn ->
      File.rm(trace_file)
    end)

    %{trace_file: trace_file}
  end

  test "new returns an empty plan" do
    assert %Plan{} = plan = CIA.new()

    assert plan.sandbox == nil
    assert plan.workspace == nil
    assert plan.harness == nil
    assert plan.mcp == %{}
    assert plan.tools == %CIA.Tool{}
    assert plan.hooks == %{}
  end

  test "sandbox stores the positional provider and preserves the generated id" do
    plan =
      CIA.new()
      |> CIA.sandbox(:local, metadata: %{source: "test"}, lifecycle: :ephemeral)

    sandbox_id = plan.sandbox.id

    updated_plan = CIA.sandbox(plan, :local, mode: :workspace_write)

    assert updated_plan.sandbox.id == sandbox_id
    assert updated_plan.sandbox.provider == :local
    assert updated_plan.sandbox.lifecycle == :ephemeral
    assert updated_plan.sandbox.metadata == %{source: "test"}
    assert updated_plan.sandbox.mode == :workspace_write
  end

  test "workspace stores the positional kind and root" do
    plan = CIA.new() |> CIA.workspace(:directory, root: "/sandbox", metadata: %{team: "cia"})

    assert plan.workspace.kind == :directory
    assert plan.workspace.root == "/sandbox"
    assert plan.workspace.metadata == %{team: "cia"}
    assert String.starts_with?(plan.workspace.id, "workspace_")
  end

  test "harness stores the positional implementation and config" do
    command = {"python3", ["/tmp/fake_codex.py"]}

    plan =
      CIA.new()
      |> CIA.harness(:codex, auth: {:api_key, "test-key"}, command: command)

    assert plan.harness.harness == :codex
    assert plan.harness.config[:auth] == {:api_key, "test-key"}
    assert plan.harness.config[:command] == command
    assert String.starts_with?(plan.harness.id, "agent_")
  end

  test "mcp can be declared before the harness and is compiled into the harness config" do
    plan =
      CIA.new()
      |> CIA.mcp(:filesystem,
        transport: :stdio,
        command: "npx",
        args: ["-y", "@modelcontextprotocol/server-filesystem", "/workspace"]
      )
      |> CIA.harness(:codex, auth: {:api_key, "test-key"})

    assert Map.has_key?(plan.mcp, :filesystem)
    assert Map.has_key?(plan.harness.mcp, :filesystem)

    assert plan.harness.mcp[:filesystem].command == "npx"

    assert plan.harness.mcp[:filesystem].args == [
             "-y",
             "@modelcontextprotocol/server-filesystem",
             "/workspace"
           ]
  end

  test "tool rules can be declared before the harness and accumulate on the plan" do
    plan =
      CIA.new()
      |> CIA.tool(allow: :shell)
      |> CIA.tool(allow: {:mcp, :filesystem, :all}, approval: :on_request)
      |> CIA.harness(:codex, auth: {:api_key, "test-key"})

    assert plan.tools.allow == [:shell, {:mcp, :filesystem, :all}]
    assert plan.tools.approval == :on_request
    assert plan.harness.tools.allow == [:shell, {:mcp, :filesystem, :all}]
    assert plan.harness.tools.approval == :on_request
  end

  test "hook stores lifecycle callbacks on the plan" do
    before_start = fn _context -> :ok end
    after_start = fn _context -> :ok end

    plan =
      CIA.new()
      |> CIA.before_start(before_start)
      |> CIA.hook(:after_start, after_start)

    assert plan.hooks.before_start == [before_start]
    assert plan.hooks.after_start == [after_start]
  end

  test "start rejects cwd on harness config" do
    plan =
      CIA.new()
      |> CIA.harness(:codex, cwd: "/sandbox")

    assert CIA.start(plan) == {:error, {:invalid_option, {:harness, :cwd}}}
  end

  test "start rejects unsupported sandbox lifecycle combinations" do
    plan =
      CIA.new()
      |> CIA.sandbox(:local, lifecycle: :durable)
      |> CIA.workspace(:directory, root: "/sandbox")

    assert CIA.start(plan) == {:error, {:unsupported_sandbox_lifecycle, :local, :durable}}
  end

  test "starts an agent against the fake stdio app-server", %{trace_file: trace_file} do
    {:ok, agent} = start_agent(trace_file)

    assert agent.status == :running
    assert is_pid(agent.pid)
  end

  test "runs start hooks relative to the agent lifecycle", %{trace_file: trace_file} do
    parent = self()

    {:ok, agent} =
      start_agent(trace_file, %{}, fn plan ->
        plan
        |> CIA.before_start(fn %{agent: agent, sandbox: sandbox} ->
          send(parent, {:before_start, agent.status, sandbox.__struct__, sandbox.status})
          :ok
        end)
        |> CIA.after_start(fn %{agent: agent, sandbox: sandbox, result: {:ok, started_agent}} ->
          send(
            parent,
            {:after_start, agent.status, sandbox.__struct__, sandbox.status, started_agent.status}
          )

          :ok
        end)
      end)

    assert agent.status == :running
    assert_receive {:before_start, :starting, CIA.Sandbox, :running}
    assert_receive {:after_start, :running, CIA.Sandbox, :running, :running}
  end

  test "runs stop hooks around agent shutdown", %{trace_file: trace_file} do
    parent = self()

    {:ok, agent} =
      start_agent(trace_file, %{}, fn plan ->
        plan
        |> CIA.before_stop(fn %{agent: agent, sandbox: sandbox, reason: reason} ->
          send(parent, {:before_stop, agent.status, sandbox.__struct__, sandbox.status, reason})
          :ok
        end)
        |> CIA.after_stop(fn %{agent: agent, sandbox: sandbox, reason: reason, result: result} ->
          send(
            parent,
            {:after_stop, agent.status, sandbox.__struct__, sandbox.status, reason, result}
          )

          :ok
        end)
      end)

    assert :ok = CIA.stop(agent)
    refute Process.alive?(agent.pid)
    assert_receive {:before_stop, :running, CIA.Sandbox, :running, :normal}
    assert_receive {:after_stop, :running, CIA.Sandbox, :running, :normal, :ok}
  end

  test "threads user-defined hook state across lifecycle hooks", %{trace_file: trace_file} do
    parent = self()

    {:ok, agent} =
      start_agent(trace_file, %{}, fn plan ->
        plan
        |> CIA.before_start(fn %{state: state} ->
          send(parent, {:before_start_state, state})
          {:ok, Map.put(state, :started, true)}
        end)
        |> CIA.after_start(fn %{state: state} ->
          send(parent, {:after_start_state, state})
          {:ok, Map.put(state, :after_started, true)}
        end)
        |> CIA.before_stop(fn %{state: state} ->
          send(parent, {:before_stop_state, state})
          :ok
        end)
        |> CIA.after_stop(fn %{state: state} ->
          send(parent, {:after_stop_state, state})
          :ok
        end)
      end)

    assert agent.status == :running
    assert_receive {:before_start_state, %{}}
    assert_receive {:after_start_state, %{started: true}}

    assert :ok = CIA.stop(agent)
    assert_receive {:before_stop_state, %{started: true, after_started: true}}
    assert_receive {:after_stop_state, %{started: true, after_started: true}}
  end

  test "rebroadcasts sandbox watch events to agent subscribers", %{trace_file: trace_file} do
    {:ok, agent} = start_agent(trace_file)
    assert :ok = CIA.subscribe(agent)

    send(
      agent.pid,
      {:cia_sandbox_watch, "watch_1", {:event, %{type: :write, path: "/sandbox/demo.txt"}}}
    )

    assert_receive {:cia, ^agent,
                    {:sandbox, :watch, "watch_1",
                     {:event, %{type: :write, path: "/sandbox/demo.txt"}}}}
  end

  test "broadcasts normalized request events and preserves raw harness events", %{
    trace_file: trace_file
  } do
    scenario = %{
      events: %{
        "turn/start" => [
          %{
            id: 91,
            method: "item/commandExecution/requestApproval",
            params: %{
              "itemId" => "item_1",
              "threadId" => "thread_test",
              "turnId" => "turn_test",
              "command" => ["git", "push"],
              "cwd" => "/sandbox",
              "availableDecisions" => ["accept", "acceptForSession", "decline", "cancel"]
            }
          }
        ]
      }
    }

    {:ok, agent} = start_agent(trace_file, scenario)
    assert :ok = CIA.subscribe(agent)
    {:ok, thread} = CIA.thread(agent, cwd: "/sandbox")

    {:ok, _turn} = CIA.turn(agent, thread, "Ship it")

    assert_receive {:cia, ^agent,
                    {:request, :approval,
                     %{
                       id: 91,
                       kind: :command,
                       command: ["git", "push"],
                       cwd: "/sandbox",
                       available_decisions: [:approve, :approve_for_session, :deny, :cancel]
                     }}}

    assert_receive {:cia, ^agent,
                    {:harness, :codex,
                     {:server_request, %{id: 91, method: "item/commandExecution/requestApproval"}}}}
  end

  test "subscribe can filter to normalized request events only", %{trace_file: trace_file} do
    scenario = %{
      events: %{
        "turn/start" => [
          %{
            id: 77,
            method: "item/fileChange/requestApproval",
            params: %{
              "itemId" => "item_2",
              "threadId" => "thread_test",
              "turnId" => "turn_test",
              "grantRoot" => "/sandbox"
            }
          }
        ]
      }
    }

    {:ok, agent} = start_agent(trace_file, scenario)
    assert :ok = CIA.subscribe(agent, self(), events: [:request])
    {:ok, thread} = CIA.thread(agent, cwd: "/sandbox")

    {:ok, _turn} = CIA.turn(agent, thread, "Edit it")

    assert_receive {:cia, ^agent,
                    {:request, :approval, %{id: 77, kind: :file_change, grant_root: "/sandbox"}}}

    refute_receive {:cia, ^agent, {:turn, :started, _}}
    refute_receive {:cia, ^agent, {:harness, :codex, _}}
  end

  test "resolve sends normalized decisions back to the harness transport", %{
    trace_file: trace_file
  } do
    scenario = %{
      events: %{
        "turn/start" => [
          %{
            id: 51,
            method: "item/commandExecution/requestApproval",
            params: %{
              "itemId" => "item_1",
              "threadId" => "thread_test",
              "turnId" => "turn_test"
            }
          }
        ]
      }
    }

    {:ok, agent} = start_agent(trace_file, scenario)
    assert :ok = CIA.subscribe(agent, self(), events: [:request])
    {:ok, thread} = CIA.thread(agent, cwd: "/sandbox")

    {:ok, _turn} = CIA.turn(agent, thread, "Deploy it")

    assert_receive {:cia, ^agent, {:request, :approval, %{id: 51}}}
    assert :ok = CIA.resolve(agent, 51, :approve_for_session)

    assert response_payload(trace_file, 51)["result"] == "acceptForSession"
  end

  test "creates a thread and forwards thread options", %{trace_file: trace_file} do
    {:ok, agent} = start_agent(trace_file)

    {:ok, thread} =
      CIA.thread(agent,
        cwd: "/sandbox",
        model: "gpt-5.4",
        system_prompt: "Be exact",
        metadata: %{source: "integration"}
      )

    assert thread.id == "thread_test"
    assert thread.status == :active
    assert thread.metadata == %{source: "integration"}

    assert request_payload(trace_file, "thread/start")["params"] == %{
             "baseInstructions" => "Be exact",
             "cwd" => "/sandbox",
             "model" => "gpt-5.4"
           }
  end

  test "creates a thread with harness instructions layered before the thread prompt", %{
    trace_file: trace_file
  } do
    instruction_file =
      Path.join(System.tmp_dir!(), "cia-instructions-#{System.unique_integer([:positive])}.md")

    File.write!(instruction_file, "Read the project docs first.")

    on_exit(fn ->
      File.rm(instruction_file)
    end)

    {:ok, agent} =
      start_agent(trace_file, %{}, fn plan ->
        CIA.harness(plan, :codex,
          instructions: [
            {:text, "You are a careful staff engineer."},
            {:file, instruction_file},
            :project_files
          ]
        )
      end)

    {:ok, _thread} =
      CIA.thread(agent,
        cwd: "/sandbox",
        system_prompt: "For this thread, prioritize regression risk."
      )

    assert request_payload(trace_file, "thread/start")["params"] == %{
             "baseInstructions" =>
               "You are a careful staff engineer.\n\nRead the project docs first.\n\nFor this thread, prioritize regression risk.",
             "cwd" => "/sandbox"
           }
  end

  test "starts a turn and records fake server notifications", %{trace_file: trace_file} do
    scenario = %{
      events: %{
        "turn/start" => [
          %{
            method: "turn/updated",
            params: %{"turnId" => "turn_test", "status" => "running"}
          }
        ]
      }
    }

    {:ok, agent} = start_agent(trace_file, scenario)
    {:ok, thread} = CIA.thread(agent, cwd: "/sandbox")

    {:ok, turn} =
      CIA.turn(agent, thread, "Build it",
        reasoning_effort: "medium",
        metadata: %{kind: "build"}
      )

    assert turn.id == "turn_test"
    assert turn.status == :running
    assert turn.metadata == %{kind: "build"}

    assert request_payload(trace_file, "turn/start")["params"] == %{
             "approvalPolicy" => "never",
             "cwd" => "/sandbox",
             "effort" => "medium",
             "input" => [%{"text" => "Build it", "type" => "text"}],
             "sandboxPolicy" => %{
               "type" => "workspaceWrite",
               "writableRoots" => ["/sandbox"],
               "networkAccess" => false,
               "excludeTmpdirEnvVar" => false,
               "excludeSlashTmp" => false
             },
             "threadId" => "thread_test"
           }

    assert notification_payload(trace_file, "turn/updated")["params"] == %{
             "turnId" => "turn_test",
             "status" => "running"
           }
  end

  test "steers and cancels a running turn", %{trace_file: trace_file} do
    {:ok, agent} = start_agent(trace_file)
    {:ok, thread} = CIA.thread(agent, cwd: "/sandbox")
    {:ok, turn} = CIA.turn(agent, thread, "Build it")

    assert :ok = CIA.steer(agent, turn, "Add tests")

    assert {:ok, cancelled_turn} = CIA.cancel(agent, turn)
    assert cancelled_turn.status == :cancelled

    assert request_payload(trace_file, "turn/steer")["params"] == %{
             "expectedTurnId" => "turn_test",
             "input" => [%{"text" => "Add tests", "type" => "text"}],
             "threadId" => "thread_test"
           }

    assert request_payload(trace_file, "turn/interrupt")["params"] == %{
             "threadId" => "thread_test",
             "turnId" => "turn_test"
           }
  end

  defp start_agent(trace_file, scenario \\ %{}, plan_fun \\ & &1) do
    config =
      CIA.new()
      |> CIA.sandbox(:local)
      |> CIA.workspace(:directory, root: "/sandbox")
      |> CIA.harness(
        :codex,
        command: FakeCodexServer.command(trace_file: trace_file, scenario: scenario)
      )
      |> plan_fun.()

    result = CIA.start(config)

    case result do
      {:ok, agent} ->
        on_exit(fn ->
          if Process.alive?(agent.pid) do
            CIA.stop(agent)
          end
        end)

      _ ->
        :ok
    end

    result
  end

  defp request_payload(trace_file, method) do
    wait_for_trace_entry(trace_file, fn entry ->
      entry["direction"] == "received" and get_in(entry, ["payload", "method"]) == method
    end)
    |> then(fn entry -> entry["payload"] end)
  end

  defp notification_payload(trace_file, method) do
    wait_for_trace_entry(trace_file, fn entry ->
      entry["direction"] == "sent" and get_in(entry, ["payload", "method"]) == method
    end)
    |> then(fn entry -> entry["payload"] end)
  end

  defp response_payload(trace_file, id) do
    wait_for_trace_entry(trace_file, fn entry ->
      get_in(entry, ["payload", "id"]) == id and
        get_in(entry, ["payload", "result"]) != nil and
        entry["direction"] in ["response", "received"]
    end)
    |> then(fn entry -> entry["payload"] end)
  end

  defp wait_for_trace_entry(trace_file, matcher, attempts \\ 20)

  defp wait_for_trace_entry(trace_file, matcher, attempts) when attempts > 0 do
    case trace_file |> FakeCodexServer.read_trace!() |> Enum.find(matcher) do
      nil ->
        Process.sleep(10)
        wait_for_trace_entry(trace_file, matcher, attempts - 1)

      entry ->
        entry
    end
  end

  defp wait_for_trace_entry(_trace_file, _matcher, 0), do: nil
end
