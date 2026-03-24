defmodule CIA.SandboxTest do
  use ExUnit.Case, async: true

  alias CIA.Sandbox

  defmodule FakeSandbox do
    def start(sandbox, opts), do: {:ok, %{sandbox: sandbox, opts: opts}}
    def stop(_sandbox), do: :ok

    def cmd(%{sandbox: sandbox}, command, args, opts) do
      output = "#{sandbox.id}:#{command}:#{Enum.join(args, ",")}:#{Keyword.get(opts, :cwd, "")}"
      {collect(output, opts), 0}
    end

    defp collect(output, opts) do
      case Keyword.fetch(opts, :into) do
        {:ok, into} when is_binary(into) ->
          into <> output

        {:ok, into} ->
          {acc, collector} = Collectable.into(into)
          acc = collector.(acc, {:cont, output})
          collector.(acc, :done)

        :error ->
          output
      end
    end
  end

  defmodule SandboxWithoutCmd do
    def start(_sandbox, _opts), do: {:ok, :started}
    def stop(_sandbox), do: :ok
  end

  setup do
    tmp_dir =
      Path.join(System.tmp_dir!(), "cia-sandbox-test-#{System.unique_integer([:positive])}")

    File.rm_rf!(tmp_dir)
    File.mkdir_p!(tmp_dir)

    on_exit(fn ->
      File.rm_rf(tmp_dir)
    end)

    %{tmp_dir: tmp_dir}
  end

  test "new builds a sandbox and stores config separately from metadata" do
    assert {:ok, sandbox} =
             Sandbox.new(
               id: "sandbox_1",
               provider: :local,
               mode: :workspace_write,
               metadata: %{source: "test"}
             )

    assert sandbox.id == "sandbox_1"
    assert sandbox.provider == :local
    assert sandbox.config == %{lifecycle: :ephemeral, mode: :workspace_write}
    assert sandbox.metadata == %{source: "test"}
  end

  test "new defaults Sprite lifecycle to ephemeral" do
    assert {:ok, sandbox} =
             Sandbox.new(
               id: "sandbox_1",
               provider: :sprite,
               token: "sprite-token"
             )

    assert sandbox.config == %{lifecycle: :ephemeral, token: "sprite-token"}
  end

  test "new requires a provider" do
    assert Sandbox.new(id: "sandbox_1") == {:error, {:missing_option, :provider}}
  end

  test "new rejects non-map metadata" do
    assert Sandbox.new(id: "sandbox_1", provider: :local, metadata: [:bad]) ==
             {:error, {:invalid_metadata, :expected_map}}
  end

  test "module_for resolves built-in and custom providers" do
    assert Sandbox.module_for(:local) == {:ok, CIA.Sandbox.Local}
    assert Sandbox.module_for(:sprite) == {:ok, CIA.Sandbox.Sprite}
    assert Sandbox.module_for(FakeSandbox) == {:ok, FakeSandbox}
  end

  test "module_for rejects invalid providers" do
    assert Sandbox.module_for("local") == {:error, {:invalid_sandbox, "local"}}
  end

  test "new rejects unsupported local sandbox lifecycles" do
    assert Sandbox.new(id: "sandbox_1", provider: :local, lifecycle: :durable) ==
             {:error, {:unsupported_sandbox_lifecycle, :local, :durable}}
  end

  test "new rejects invalid lifecycle values" do
    assert Sandbox.new(
             id: "sandbox_1",
             provider: :sprite,
             lifecycle: :bogus,
             token: "sprite-token"
           ) ==
             {:error, {:invalid_option, {:lifecycle, :bogus}}}
  end

  test "new requires a name for durable Sprite sandboxes" do
    assert Sandbox.new(
             id: "sandbox_1",
             provider: :sprite,
             lifecycle: :durable,
             token: "sprite-token"
           ) ==
             {:error, {:missing_option, :name}}
  end

  test "new requires a name for attached Sprite sandboxes" do
    assert Sandbox.new(
             id: "sandbox_1",
             provider: :sprite,
             lifecycle: :attached,
             token: "sprite-token"
           ) ==
             {:error, {:missing_option, :name}}
  end

  test "start delegates to the sandbox module" do
    sandbox = %Sandbox{id: "sandbox_1", provider: FakeSandbox}

    assert {:ok, started} = Sandbox.start(sandbox, command: {"echo", ["ok"]})
    assert started.__struct__ == Sandbox
    assert started.status == :running
    assert started.runtime == %{sandbox: sandbox, opts: [command: {"echo", ["ok"]}]}
  end

  test "local start returns command_not_found for missing executables" do
    {:ok, sandbox} = Sandbox.new(id: "sandbox_2", provider: :local)

    assert Sandbox.start(sandbox, command: ["cia-command-that-does-not-exist"]) ==
             {:error, {:command_not_found, "cia-command-that-does-not-exist"}}
  end

  test "local start carries the normalized lifecycle into the runtime" do
    {:ok, sandbox} = Sandbox.new(id: "sandbox_2", provider: :local)

    assert {:ok, runtime} = Sandbox.start(sandbox, command: ["/bin/sh", "-lc", "sleep 1"])
    assert runtime.status == :running
    assert runtime.runtime.lifecycle == :ephemeral

    assert {:ok, stopped} = Sandbox.stop(runtime)
    assert stopped.status == :stopped
    assert stopped.runtime == nil
  end

  test "cmd delegates to the sandbox module and returns System.cmd-style output" do
    sandbox = start_fake_sandbox!()

    assert Sandbox.cmd(sandbox, "echo", ["ok"], cwd: "/tmp") == {"sandbox_1:echo:ok:/tmp", 0}
  end

  test "cmd returns sandbox errors when the executable is missing" do
    sandbox = start_local_sandbox!()

    assert Sandbox.cmd(sandbox, "cia-command-that-does-not-exist") ==
             {:error, {:command_not_found, "cia-command-that-does-not-exist"}}
  end

  test "cmd returns output and status for non-zero exits" do
    sandbox = start_local_sandbox!()

    assert Sandbox.cmd(sandbox, "/bin/sh", ["-lc", "printf failing && exit 7"]) ==
             {"failing", 7}
  end

  test "cmd returns an unsupported operation error when cmd is not exported" do
    sandbox = start_sandbox_without_cmd!()

    assert Sandbox.cmd(sandbox, "echo", ["ok"]) ==
             {:error, {:unsupported_sandbox_operation, :cmd}}
  end

  test "cmd respects the into option" do
    sandbox = start_fake_sandbox!()

    assert Sandbox.cmd(sandbox, "echo", ["ok"], into: []) ==
             {["sandbox_1:echo:ok:"], 0}
  end

  test "local filesystem operations work against the runtime cwd", %{tmp_dir: tmp_dir} do
    sandbox = start_local_sandbox!()

    assert :ok = Sandbox.mkdir(sandbox, "workspace", cwd: tmp_dir)

    assert :ok =
             Sandbox.write(sandbox, "workspace/demo.txt", "hello", cwd: tmp_dir, mkdir_p: true)

    assert {:ok, "hello"} = Sandbox.read(sandbox, "workspace/demo.txt", cwd: tmp_dir)

    assert {:ok, entries} = Sandbox.ls(sandbox, "workspace", cwd: tmp_dir)
    assert Enum.any?(entries, &(&1.name == "demo.txt"))
    assert Enum.any?(entries, &(&1.size == 5 and &1.is_dir == false))

    assert :ok =
             Sandbox.cp(sandbox, "workspace/demo.txt", "workspace/demo-copy.txt", cwd: tmp_dir)

    assert :ok =
             Sandbox.mv(sandbox, "workspace/demo-copy.txt", "workspace/demo-moved.txt",
               cwd: tmp_dir
             )

    assert {:ok, "hello"} = Sandbox.read(sandbox, "workspace/demo-moved.txt", cwd: tmp_dir)

    assert :ok = Sandbox.rm(sandbox, "workspace/demo-moved.txt", cwd: tmp_dir)
    assert {:error, :enoent} = Sandbox.read(sandbox, "workspace/demo-moved.txt", cwd: tmp_dir)
  end

  test "local watch emits filesystem events", %{tmp_dir: tmp_dir} do
    sandbox = start_local_sandbox!()

    assert {:ok, watch} =
             Sandbox.watch(sandbox, [tmp_dir], recursive: true, interval: 50, owner: self())

    watch_id = watch.id

    assert_receive {:cia_sandbox_watch, ^watch_id, :ready}, 1_000

    assert :ok = Sandbox.write(sandbox, "watched.txt", "hello", cwd: tmp_dir)

    assert_receive {:cia_sandbox_watch, ^watch_id, {:event, event}}, 1_000
    assert event.type in [:create, :write]
    assert String.ends_with?(event.path, "watched.txt")

    assert :ok = Sandbox.unwatch(watch)
  end

  test "checkpoint and restore return unsupported for local" do
    sandbox = start_local_sandbox!()

    assert Sandbox.checkpoint(sandbox) == {:error, {:unsupported_sandbox_operation, :checkpoint}}

    assert Sandbox.restore(sandbox, "checkpoint_1") ==
             {:error, {:unsupported_sandbox_operation, :restore}}
  end

  test "stop delegates to the sandbox module" do
    sandbox = %Sandbox{id: "sandbox_1", provider: FakeSandbox}

    assert Sandbox.stop(sandbox) == {:ok, %Sandbox{sandbox | runtime: nil, status: :stopped}}
  end

  defp start_local_sandbox! do
    {:ok, sandbox} =
      Sandbox.new(
        id: "sandbox_#{System.unique_integer([:positive])}",
        provider: :local
      )

    {:ok, runtime} = Sandbox.start(sandbox, command: ["/bin/sh", "-lc", "sleep 30"])

    ExUnit.Callbacks.on_exit(fn ->
      _ = Sandbox.stop(runtime)
    end)

    runtime
  end

  defp start_fake_sandbox! do
    sandbox = %Sandbox{id: "sandbox_1", provider: FakeSandbox}
    {:ok, runtime} = Sandbox.start(sandbox, command: {"echo", ["ok"]})
    runtime
  end

  defp start_sandbox_without_cmd! do
    sandbox = %Sandbox{id: "sandbox_1", provider: SandboxWithoutCmd}
    {:ok, runtime} = Sandbox.start(sandbox)
    runtime
  end
end
