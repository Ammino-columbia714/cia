defmodule CIA.Sandbox.Sprite do
  @moduledoc false

  @behaviour CIA.Sandbox

  alias CIA.Sandbox.Channel
  alias CIA.Sandbox.Checkpoint
  alias CIA.Sandbox.Sprite.Channel.Exec
  alias CIA.Sandbox.Sprite.Channel.Watch, as: WatchChannel
  alias CIA.Sandbox.Watch

  @default_base_url "https://api.sprites.dev"
  @supported_lifecycles [:ephemeral, :durable, :attached]

  defstruct [
    :name,
    :token,
    :channel,
    :lifecycle,
    mode: :workspace_write,
    base_url: @default_base_url,
    metadata: %{}
  ]

  def normalize_config(config) when is_map(config) do
    with {:ok, lifecycle} <- normalize_lifecycle(Map.get(config, :lifecycle, :ephemeral)),
         :ok <- validate_name_requirement(Map.get(config, :name), lifecycle) do
      {:ok, Map.put(config, :lifecycle, lifecycle)}
    end
  end

  def start(%CIA.Sandbox{provider: provider, config: config, metadata: metadata}, opts)
      when provider in [:sprite, :sprites] and is_list(opts) do
    opts =
      config
      |> Map.to_list()
      |> Keyword.merge(opts)
      |> Keyword.put_new(:metadata, metadata)

    mode = Keyword.get(opts, :mode, :workspace_write)
    metadata = Keyword.get(opts, :metadata, %{})
    env = Keyword.get(opts, :env, %{})
    base_url = Keyword.get(opts, :base_url, @default_base_url)
    checkpoint = Keyword.get(opts, :checkpoint)

    with {:ok, start_opts} <- start_options(opts, mode, metadata, env, base_url, checkpoint),
         {:ok, cleanup_policy} <-
           prepare_sprite(
             start_opts.base_url,
             start_opts.name,
             start_opts.token,
             start_opts.lifecycle
           ) do
      case maybe_restore_checkpoint(
             start_opts.base_url,
             start_opts.name,
             start_opts.token,
             start_opts.checkpoint
           ) do
        :ok ->
          case Exec.start_link(
                 name: start_opts.name,
                 token: start_opts.token,
                 base_url: start_opts.base_url,
                 command: start_opts.command,
                 env: start_opts.env
               ) do
            {:ok, pid} ->
              {:ok,
               %__MODULE__{
                 name: start_opts.name,
                 token: start_opts.token,
                 base_url: start_opts.base_url,
                 mode: start_opts.mode,
                 lifecycle: start_opts.lifecycle,
                 channel: Channel.new(Exec, pid),
                 metadata: start_opts.metadata
               }}

            {:error, reason} ->
              _ = cleanup_failed_start(start_opts, cleanup_policy)
              {:error, reason}
          end

        {:error, _reason} = error ->
          _ = cleanup_failed_start(start_opts, cleanup_policy)
          error
      end
    end
  end

  def stop(%__MODULE__{channel: %Channel{} = channel} = sandbox) do
    :ok =
      case Process.alive?(channel.pid) do
        true -> Channel.stop(channel)
        false -> :ok
      end

    case sandbox.lifecycle do
      :ephemeral ->
        delete_sprite(sandbox.base_url, sandbox.name, sandbox.token)

      _ ->
        :ok
    end
  end

  def cmd(%__MODULE__{} = sandbox, command, args, opts)
      when is_binary(command) and is_list(args) and is_list(opts) do
    case exec_command(sandbox, [command | args], opts) do
      {:ok, output} ->
        {format_cmd_output(output, opts), output.exit_code}

      {:error, {:command_failed, output}} ->
        {format_cmd_output(output, opts), output.exit_code}

      {:error, _reason} = error ->
        error
    end
  end

  def read(%__MODULE__{} = sandbox, path, opts) when is_binary(path) and is_list(opts) do
    case Req.get(
           url: read_url(sandbox.base_url, sandbox.name, path, Keyword.get(opts, :cwd)),
           headers: auth_headers(sandbox.token)
         ) do
      {:ok, %Req.Response{status: status, body: body}} when status in 200..299 ->
        {:ok, decode_file_body(body, Keyword.get(opts, :encoding, :binary))}

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, {:sprite_read_failed, status, decode_error_body(body)}}

      {:error, reason} ->
        {:error, {:sprite_read_failed, reason}}
    end
  end

  def write(%__MODULE__{} = sandbox, path, contents, opts)
      when is_binary(path) and is_list(opts) do
    query =
      []
      |> Keyword.put(:path, path)
      |> maybe_put_query("workingDir", Keyword.get(opts, :cwd))
      |> maybe_put_query("mode", Keyword.get(opts, :mode))
      |> maybe_put_query("mkdir", Keyword.get(opts, :mkdir_p, false))
      |> URI.encode_query()

    case Req.put(
           url: fs_write_url(sandbox.base_url, sandbox.name, query),
           headers: auth_headers(sandbox.token),
           body: IO.iodata_to_binary(contents)
         ) do
      {:ok, %Req.Response{status: status}} when status in 200..299 ->
        :ok

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, {:sprite_write_failed, status, decode_error_body(body)}}

      {:error, reason} ->
        {:error, {:sprite_write_failed, reason}}
    end
  end

  def ls(%__MODULE__{} = sandbox, path, opts) when is_binary(path) and is_list(opts) do
    case Req.get(
           url: list_url(sandbox.base_url, sandbox.name, path, Keyword.get(opts, :cwd)),
           headers: auth_headers(sandbox.token)
         ) do
      {:ok, %Req.Response{status: status, body: body}} when status in 200..299 ->
        {:ok, normalize_list_response(body)}

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, {:sprite_list_failed, status, decode_error_body(body)}}

      {:error, reason} ->
        {:error, {:sprite_list_failed, reason}}
    end
  end

  def mkdir(%__MODULE__{} = sandbox, path, opts) when is_binary(path) and is_list(opts) do
    command =
      case Keyword.get(opts, :parents, true) do
        true -> ["mkdir", "-p", path]
        false -> ["mkdir", path]
      end

    case exec_command(sandbox, command, cd: Keyword.get(opts, :cwd)) do
      {:ok, _output} ->
        :ok

      {:error, {:command_failed, output}} ->
        {:error, {:sprite_mkdir_failed, output.exit_code, output.stderr || output.stdout}}

      {:error, reason} ->
        {:error, {:sprite_mkdir_failed, reason}}
    end
  end

  def rm(%__MODULE__{} = sandbox, path, opts) when is_binary(path) and is_list(opts) do
    force = Keyword.get(opts, :force, false)

    body =
      %{
        path: path,
        workingDir: Keyword.get(opts, :cwd),
        recursive: Keyword.get(opts, :recursive, false),
        asRoot: false
      }
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)
      |> Map.new()

    case Req.delete(
           url: fs_delete_url(sandbox.base_url, sandbox.name),
           headers: auth_headers(sandbox.token),
           json: body
         ) do
      {:ok, %Req.Response{status: status}} when status in 200..299 ->
        :ok

      {:ok, %Req.Response{status: 404}} when force ->
        :ok

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, {:sprite_rm_failed, status, decode_error_body(body)}}

      {:error, reason} ->
        {:error, {:sprite_rm_failed, reason}}
    end
  end

  def mv(%__MODULE__{} = sandbox, source, dest, opts)
      when is_binary(source) and is_binary(dest) and is_list(opts) do
    case Req.post(
           url: rename_url(sandbox.base_url, sandbox.name),
           headers: auth_headers(sandbox.token),
           json: %{
             source: source,
             dest: dest,
             workingDir: Keyword.get(opts, :cwd),
             asRoot: false
           }
         ) do
      {:ok, %Req.Response{status: status}} when status in 200..299 ->
        :ok

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, {:sprite_mv_failed, status, decode_error_body(body)}}

      {:error, reason} ->
        {:error, {:sprite_mv_failed, reason}}
    end
  end

  def cp(%__MODULE__{} = sandbox, source, dest, opts)
      when is_binary(source) and is_binary(dest) and is_list(opts) do
    case Req.post(
           url: copy_url(sandbox.base_url, sandbox.name),
           headers: auth_headers(sandbox.token),
           json: %{
             source: source,
             dest: dest,
             workingDir: Keyword.get(opts, :cwd),
             recursive: Keyword.get(opts, :recursive, true),
             preserveAttrs: Keyword.get(opts, :preserve, false),
             asRoot: false
           }
         ) do
      {:ok, %Req.Response{status: status}} when status in 200..299 ->
        :ok

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, {:sprite_cp_failed, status, decode_error_body(body)}}

      {:error, reason} ->
        {:error, {:sprite_cp_failed, reason}}
    end
  end

  def watch(%__MODULE__{} = sandbox, paths, opts) when is_list(paths) and is_list(opts) do
    owner = Keyword.get(opts, :owner, self())
    cwd = Keyword.get(opts, :cwd)
    recursive = Keyword.get(opts, :recursive, false)
    id = watch_id()

    case WatchChannel.start_link(
           id: id,
           owner: owner,
           name: sandbox.name,
           token: sandbox.token,
           base_url: sandbox.base_url,
           paths: paths,
           cwd: cwd,
           recursive: recursive
         ) do
      {:ok, pid} ->
        {:ok, Watch.new(id, WatchChannel, pid, %{paths: paths, cwd: cwd, recursive: recursive})}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def checkpoint(%__MODULE__{} = sandbox, opts) when is_list(opts) do
    case Req.post(
           url: checkpoints_url(sandbox.base_url, sandbox.name),
           headers: auth_headers(sandbox.token),
           json: checkpoint_payload(opts)
         ) do
      {:ok, %Req.Response{status: status, body: body}} when status in 200..299 ->
        with {:ok, checkpoint_id} <- extract_checkpoint_id(body) do
          {:ok, Checkpoint.new(checkpoint_id, checkpoint_id, normalize_checkpoint_metadata(body))}
        end

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, {:sprite_checkpoint_failed, status, decode_error_body(body)}}

      {:error, reason} ->
        {:error, {:sprite_checkpoint_failed, reason}}
    end
  end

  def restore(%__MODULE__{} = sandbox, checkpoint, opts) when is_list(opts) do
    checkpoint_id = checkpoint_id(checkpoint)

    case maybe_restore_checkpoint(sandbox.base_url, sandbox.name, sandbox.token, checkpoint_id) do
      :ok -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp normalize_runtime_command({command, args})
       when is_binary(command) and is_list(args),
       do: [command | args]

  defp normalize_runtime_command(command) when is_list(command), do: command

  defp exec_command(%__MODULE__{} = sandbox, command, opts)
       when is_list(command) and is_list(opts) do
    cwd = Keyword.get(opts, :cwd)
    env = normalize_cmd_env(Keyword.get(opts, :env, %{}))
    timeout = Keyword.get(opts, :timeout, 30_000)

    case Req.post(
           url: exec_url(sandbox.base_url, sandbox.name, command, cwd, env),
           headers: auth_headers(sandbox.token),
           receive_timeout: timeout
         ) do
      {:ok, %Req.Response{status: status, body: body}} when status in 200..299 ->
        with {:ok, output} <- decode_exec_output(body) do
          case output do
            %{exit_code: 0} -> {:ok, output}
            %{exit_code: _status} -> {:error, {:command_failed, output}}
          end
        end

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, {:sprite_exec_failed, status, decode_error_body(body)}}

      {:error, reason} ->
        {:error, {:sprite_exec_failed, reason}}
    end
  end

  defp start_options(opts, mode, metadata, env, base_url, checkpoint) do
    with {:ok, lifecycle} <- normalize_lifecycle(Keyword.get(opts, :lifecycle, :ephemeral)),
         {:ok, name} <- resolve_name(Keyword.get(opts, :name), lifecycle),
         {:ok, token} <- validate_token(Keyword.get(opts, :token)) do
      {:ok,
       %{
         base_url: base_url,
         checkpoint: checkpoint,
         command: opts |> Keyword.fetch!(:command) |> normalize_runtime_command(),
         env: env,
         lifecycle: lifecycle,
         metadata: metadata,
         mode: mode,
         name: name,
         token: token
       }}
    end
  end

  defp validate_name(name) when is_binary(name) and byte_size(name) > 0, do: {:ok, name}
  defp validate_name(_), do: {:error, {:missing_option, :name}}

  defp validate_token(token) when is_binary(token) and byte_size(token) > 0, do: {:ok, token}
  defp validate_token(_), do: {:error, {:missing_option, :token}}

  defp prepare_sprite(base_url, name, token, :ephemeral) do
    case create_sprite(base_url, name, token) do
      :ok -> {:ok, :delete_on_failure}
      {:error, _reason} = error -> error
    end
  end

  defp prepare_sprite(base_url, name, token, :durable) do
    case ensure_sprite_exists(base_url, name, token) do
      :ok -> {:ok, :keep}
      {:error, _reason} = error -> error
    end
  end

  defp prepare_sprite(base_url, name, token, :attached) do
    case fetch_sprite(base_url, name, token) do
      {:ok, _body} ->
        {:ok, :keep}

      {:missing, _body} ->
        {:error, {:sprite_not_found, name}}

      {:error, {:status, status, body}} ->
        {:error, {:sprite_lookup_failed, status, body}}

      {:error, reason} ->
        {:error, {:sprite_lookup_failed, reason}}
    end
  end

  defp ensure_sprite_exists(base_url, name, token) do
    case fetch_sprite(base_url, name, token) do
      {:ok, _body} ->
        :ok

      {:missing, _body} ->
        create_sprite(base_url, name, token)

      {:error, {:status, status, body}} ->
        {:error, {:sprite_lookup_failed, status, body}}

      {:error, reason} ->
        {:error, {:sprite_lookup_failed, reason}}
    end
  end

  defp fetch_sprite(base_url, name, token) do
    case Req.get(url: sprite_url(base_url, name), headers: auth_headers(token)) do
      {:ok, %Req.Response{status: status, body: body}} when status in 200..299 ->
        {:ok, body}

      {:ok, %Req.Response{status: 404, body: body}} ->
        {:missing, decode_error_body(body)}

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, {:status, status, decode_error_body(body)}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp create_sprite(base_url, name, token) do
    case Req.post(
           url: sprites_url(base_url),
           headers: auth_headers(token),
           json: %{name: name}
         ) do
      {:ok, %Req.Response{status: status}} when status in 200..299 ->
        :ok

      {:ok, %Req.Response{status: status, body: body}} ->
        decoded = decode_error_body(body)
        {:error, {:sprite_create_failed, status, decoded}}

      {:error, reason} ->
        {:error, {:sprite_create_failed, reason}}
    end
  end

  defp delete_sprite(base_url, name, token) do
    case Req.delete(url: sprite_url(base_url, name), headers: auth_headers(token)) do
      {:ok, %Req.Response{status: status}} when status in 200..299 ->
        :ok

      {:ok, %Req.Response{status: 404}} ->
        :ok

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, {:sprite_delete_failed, status, decode_error_body(body)}}

      {:error, reason} ->
        {:error, {:sprite_delete_failed, reason}}
    end
  end

  defp maybe_restore_checkpoint(_base_url, _name, _token, nil), do: :ok

  defp maybe_restore_checkpoint(base_url, name, token, checkpoint)
       when is_binary(checkpoint) and byte_size(checkpoint) > 0 do
    case Req.post(
           url: checkpoint_restore_url(base_url, name, checkpoint),
           headers: auth_headers(token)
         ) do
      {:ok, %Req.Response{status: status, body: body}} when status in 200..299 ->
        case decode_checkpoint_restore_body(body) do
          {:ok, _decoded} -> :ok
          {:error, _reason} -> :ok
        end

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, {:sprite_checkpoint_restore_failed, status, decode_error_body(body)}}

      {:error, reason} ->
        {:error, {:sprite_checkpoint_restore_failed, reason}}
    end
  end

  defp maybe_restore_checkpoint(_base_url, _name, _token, checkpoint) do
    {:error, {:invalid_option, {:checkpoint, checkpoint}}}
  end

  defp checkpoint_restore_url(base_url, name, checkpoint) do
    uri = URI.parse(base_url)

    %URI{
      uri
      | path: "/v1/sprites/#{name}/checkpoints/#{checkpoint}/restore",
        query: nil
    }
    |> URI.to_string()
  end

  defp read_url(base_url, name, path, cwd) do
    query =
      []
      |> Keyword.put(:path, path)
      |> maybe_put_query("workingDir", cwd)
      |> URI.encode_query()

    build_url(base_url, "/v1/sprites/#{name}/fs/read", query)
  end

  defp fs_write_url(base_url, name, query) do
    build_url(base_url, "/v1/sprites/#{name}/fs/write", query)
  end

  defp list_url(base_url, name, path, cwd) do
    query =
      []
      |> Keyword.put(:path, path)
      |> maybe_put_query("workingDir", cwd)
      |> URI.encode_query()

    build_url(base_url, "/v1/sprites/#{name}/fs/list", query)
  end

  defp fs_delete_url(base_url, name),
    do: build_url(base_url, "/v1/sprites/#{name}/fs/delete", nil)

  defp rename_url(base_url, name), do: build_url(base_url, "/v1/sprites/#{name}/fs/rename", nil)
  defp copy_url(base_url, name), do: build_url(base_url, "/v1/sprites/#{name}/fs/copy", nil)

  defp checkpoints_url(base_url, name),
    do: build_url(base_url, "/v1/sprites/#{name}/checkpoints", nil)

  defp sprite_url(base_url, name) do
    uri = URI.parse(base_url)

    %URI{uri | path: "/v1/sprites/#{name}", query: nil}
    |> URI.to_string()
  end

  defp sprites_url(base_url) do
    uri = URI.parse(base_url)

    %URI{uri | path: "/v1/sprites", query: nil}
    |> URI.to_string()
  end

  defp exec_url(base_url, name, command, cwd, env) do
    uri = URI.parse(base_url)

    query =
      []
      |> append_repeated("cmd", command)
      |> maybe_put("dir", cwd)
      |> append_env(env)
      |> URI.encode_query()

    %URI{uri | path: "/v1/sprites/#{name}/exec", query: query}
    |> URI.to_string()
  end

  defp build_url(base_url, path, query) do
    uri = URI.parse(base_url)
    %URI{uri | path: path, query: query} |> URI.to_string()
  end

  defp normalize_cmd_env(env) when is_map(env), do: env
  defp normalize_cmd_env(env) when is_list(env), do: Map.new(env)

  defp format_cmd_output(output, opts) when is_map(output) and is_list(opts) do
    stdout =
      case Keyword.get(opts, :stderr_to_stdout, false) do
        true -> Map.get(output, :stdout, "") <> Map.get(output, :stderr, "")
        false -> Map.get(output, :stdout, "")
      end

    collect_into(stdout, Keyword.get(opts, :into, ""))
  end

  defp collect_into(output, into) when is_binary(into), do: into <> output

  defp collect_into(output, into) do
    {acc, collector} = Collectable.into(into)
    acc = collector.(acc, {:cont, output})
    collector.(acc, :done)
  end

  defp decode_checkpoint_restore_body(""), do: {:ok, nil}
  defp decode_checkpoint_restore_body(nil), do: {:ok, nil}
  defp decode_checkpoint_restore_body(body) when is_map(body) or is_list(body), do: {:ok, body}

  defp decode_checkpoint_restore_body(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, decoded} ->
        {:ok, decoded}

      {:error, _reason} ->
        decode_ndjson_body(body)
    end
  end

  defp decode_ndjson_body(body) do
    body
    |> String.split("\n", trim: true)
    |> Enum.reduce_while({:ok, []}, fn line, {:ok, acc} ->
      case Jason.decode(line) do
        {:ok, decoded} -> {:cont, {:ok, [decoded | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, decoded} -> {:ok, Enum.reverse(decoded)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp decode_error_body(body) when is_map(body) or is_list(body), do: body

  defp decode_error_body(body) when is_binary(body) do
    case decode_checkpoint_restore_body(body) do
      {:ok, decoded} -> decoded
      {:error, _reason} -> body
    end
  end

  defp decode_exec_output(<<3, status, _rest::binary>>) when is_integer(status) do
    {:ok, %{stdout: "", stderr: "", exit_code: status}}
  end

  defp decode_exec_output(body) when is_binary(body) do
    with {:ok, decoded} <- decode_checkpoint_restore_body(body),
         {:ok, exit_code} <- extract_exit_code(decoded) do
      {:ok,
       %{
         stdout: extract_output(decoded, "stdout"),
         stderr: extract_output(decoded, "stderr"),
         exit_code: exit_code
       }}
    end
  end

  defp extract_exit_code(%{"exit_code" => exit_code}) when is_integer(exit_code),
    do: {:ok, exit_code}

  defp extract_exit_code(%{"exitCode" => exit_code}) when is_integer(exit_code),
    do: {:ok, exit_code}

  defp extract_exit_code(%{exit_code: exit_code}) when is_integer(exit_code), do: {:ok, exit_code}
  defp extract_exit_code(%{exitCode: exit_code}) when is_integer(exit_code), do: {:ok, exit_code}
  defp extract_exit_code(other), do: {:error, {:invalid_sprite_exec_response, other}}

  defp extract_output(map, key) when is_map(map) do
    case key do
      "stdout" -> Map.get(map, "stdout") || Map.get(map, :stdout) || ""
      "stderr" -> Map.get(map, "stderr") || Map.get(map, :stderr) || ""
    end
  end

  defp decode_file_body(body, :binary) when is_binary(body), do: body
  defp decode_file_body(body, :utf8) when is_binary(body), do: body
  defp decode_file_body(body, _encoding), do: body

  defp normalize_list_response(%{"entries" => entries}) when is_list(entries), do: entries
  defp normalize_list_response(%{entries: entries}) when is_list(entries), do: entries
  defp normalize_list_response(other), do: other

  defp checkpoint_payload(opts) do
    opts
    |> Enum.into(%{})
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp extract_checkpoint_id(body) when is_map(body) do
    cond do
      is_binary(body["id"]) and body["id"] != "" -> {:ok, body["id"]}
      is_binary(body["checkpoint"]) and body["checkpoint"] != "" -> {:ok, body["checkpoint"]}
      is_binary(body["name"]) and body["name"] != "" -> {:ok, body["name"]}
      true -> {:error, {:invalid_checkpoint_response, body}}
    end
  end

  defp extract_checkpoint_id(body) when is_binary(body) do
    case decode_checkpoint_restore_body(body) do
      {:ok, decoded} -> extract_checkpoint_id(decoded)
      {:error, reason} -> {:error, {:invalid_checkpoint_response, reason}}
    end
  end

  defp extract_checkpoint_id(other), do: {:error, {:invalid_checkpoint_response, other}}

  defp normalize_checkpoint_metadata(body) when is_map(body), do: body
  defp normalize_checkpoint_metadata(_body), do: %{}

  defp checkpoint_id(%Checkpoint{provider_ref: provider_ref}) when is_binary(provider_ref),
    do: provider_ref

  defp checkpoint_id(%Checkpoint{id: id}), do: id
  defp checkpoint_id(id) when is_binary(id), do: id

  defp maybe_put_query(query, _key, nil), do: query
  defp maybe_put_query(query, key, false), do: Keyword.put(query, String.to_atom(key), false)
  defp maybe_put_query(query, key, value), do: Keyword.put(query, String.to_atom(key), value)

  defp watch_id do
    "watch_" <> Integer.to_string(System.unique_integer([:positive, :monotonic]))
  end

  defp append_repeated(query, _key, []), do: query
  defp append_repeated(query, key, values), do: query ++ Enum.map(values, &{key, &1})

  defp maybe_put(query, _key, nil), do: query
  defp maybe_put(query, key, value), do: Keyword.put(query, String.to_atom(key), value)

  defp append_env(query, env) when env == %{}, do: query

  defp append_env(query, env) when is_map(env),
    do: query ++ Enum.map(env, fn {key, value} -> {"env", "#{key}=#{value}"} end)

  defp auth_headers(token) do
    [
      {"authorization", "Bearer #{token}"},
      {"accept", "application/json"}
    ]
  end

  defp normalize_lifecycle(lifecycle) when lifecycle in @supported_lifecycles,
    do: {:ok, lifecycle}

  defp normalize_lifecycle(lifecycle) do
    {:error, {:invalid_option, {:lifecycle, lifecycle}}}
  end

  defp validate_name_requirement(name, lifecycle) when lifecycle in [:durable, :attached] do
    validate_name(name)
    |> case do
      {:ok, _name} -> :ok
      {:error, _reason} = error -> error
    end
  end

  defp validate_name_requirement(_name, :ephemeral), do: :ok

  defp resolve_name(name, lifecycle) when lifecycle in [:durable, :attached],
    do: validate_name(name)

  defp resolve_name(name, :ephemeral) do
    case name do
      nil -> {:ok, generated_name()}
      _ -> validate_name(name)
    end
  end

  defp cleanup_failed_start(_start_opts, :keep), do: :ok

  defp cleanup_failed_start(start_opts, :delete_on_failure) do
    delete_sprite(start_opts.base_url, start_opts.name, start_opts.token)
  end

  defp generated_name do
    "cia-sprite-" <> Integer.to_string(System.unique_integer([:positive, :monotonic]))
  end
end
