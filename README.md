# CIA - Central Intelligence Agent

[![Hex pm](https://img.shields.io/hexpm/v/cia.svg)](https://hex.pm/packages/cia)
[![Hexdocs](https://img.shields.io/badge/hexdocs-latest-blue.svg)](https://hexdocs.pm/cia)

Manage background agents directly in your Elixir app.

## Overview

CIA is an opinionated library for running background agents from an Elixir app.

It separates three runtime concerns:

- the sandbox: where that agent is running
- the workspace: what filesystem scope that work should happen in
- the harness: what agent implementation is running

And it manages three core runtime models:

- agents: a single running managed agent
- threads: a conversation handle owned by an agent
- turns: a single unit of model work on a thread

Each agent runs as a GenServer. CIA can start agents directly or under your own
supervisor. Right now, CIA is entirely in-memory. Agent, thread, and turn state
does not survive application restarts.

## Installation

Install from Hex:

```elixir
def deps do
  [
    {:cia, "~> 0.0.1"}
  ]
end
```

## Usage

```elixir
openai_api_key = System.fetch_env!("OPENAI_API_KEY")

config =
  CIA.new()
  |> CIA.sandbox(:local)
  |> CIA.workspace(:directory, root: "/sandbox")
  |> CIA.before_start(fn %{sandbox: sandbox} ->
    with {_, 0} <- CIA.Sandbox.cmd(sandbox, "mkdir", ["-p", "/sandbox"]) do
      :ok
    end
  end)
  |> CIA.harness(:codex, auth: {:api_key, openai_api_key})

{:ok, agent} = CIA.start(config)
```

To start an agent under your own supervisor instead:

```elixir
{:ok, agent} = CIA.start(config, supervisor: MyApp.CIAAgentSupervisor)
```

After startup, create a thread and submit a turn:

```elixir
:ok = CIA.subscribe(agent)

{:ok, thread} =
  CIA.thread(agent,
    cwd: "/sandbox",
    model: "gpt-5.4"
  )

{:ok, turn} =
  CIA.turn(agent, thread, "Create lib/demo.ex with a function that returns :ok.")
```

## Events

CIA supports agent-level subscriptions through `subscribe/2` and `subscribe/3`.

Subscribers currently receive messages in this form:

```elixir
{:cia, %CIA.Agent{}, event}
```

CIA emits normalized events for requests, threads, turns, and sandbox watch
activity:

```elixir
{:cia, agent, {:request, :approval, payload}}
{:cia, agent, {:request, :user_input, payload}}
{:cia, agent, {:request, :resolved, payload}}
{:cia, agent, {:thread, :started, payload}}
{:cia, agent, {:turn, :status, payload}}
{:cia, agent, {:sandbox, :watch, watch_id, payload}}
```

Raw harness payloads are still forwarded for compatibility:

```elixir
{:cia, agent, {:harness, :codex, payload}}
```

To filter delivery to specific event families:

```elixir
CIA.subscribe(agent, self(), events: [:request, :turn])
```

Pending normalized requests can be answered through `CIA.resolve/3`:

```elixir
CIA.resolve(agent, request_id, :approve)
CIA.resolve(agent, request_id, :approve_for_session)
CIA.resolve(agent, request_id, :deny)
CIA.resolve(agent, request_id, :cancel)
CIA.resolve(agent, request_id, {:input, "Use the online migration path."})
```

## Supported Harnesses

CIA currently supports Codex through its app-server implementation.

## Supported Sandboxes

CIA currently supports `:local` and `:sprite` (see [Sprite](https://sprites.dev)) based sandboxes.

## License

Copyright (c) 2026 Sean Moriarity

Licensed under the Apache License, Version 2.0 (the "License"); you may not use this file except in compliance with the License. You may obtain a copy of the License at http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software distributed under the License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the License for the specific language governing permissions and limitations under the License.
