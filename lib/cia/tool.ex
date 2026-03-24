defmodule CIA.Tool do
  @moduledoc false

  defstruct allow: [], deny: [], approval: nil

  @type t :: %__MODULE__{
          allow: [tool_ref()],
          deny: [tool_ref()],
          approval: atom() | String.t() | nil
        }

  @type tool_ref ::
          :all
          | atom()
          | String.t()
          | {:mcp, atom() | String.t(), :all | atom() | String.t()}

  def new(opts) when is_list(opts) do
    with {:ok, allow} <- normalize_refs(Keyword.get_values(opts, :allow)),
         {:ok, deny} <- normalize_refs(Keyword.get_values(opts, :deny)),
         {:ok, approval} <- normalize_approval(Keyword.get_values(opts, :approval)) do
      {:ok, %__MODULE__{allow: allow, deny: deny, approval: approval}}
    end
  end

  def new(_), do: {:error, {:invalid_option, :tool}}

  def merge(%__MODULE__{} = current, %__MODULE__{} = delta) do
    %__MODULE__{
      allow: current.allow ++ delta.allow,
      deny: current.deny ++ delta.deny,
      approval: delta.approval || current.approval
    }
  end

  defp normalize_refs(values) when is_list(values) do
    values
    |> List.flatten()
    |> Enum.reduce_while({:ok, []}, fn value, {:ok, acc} ->
      case normalize_ref(value) do
        {:ok, ref} -> {:cont, {:ok, acc ++ [ref]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp normalize_ref(:all), do: {:ok, :all}
  defp normalize_ref(value) when is_atom(value), do: {:ok, value}
  defp normalize_ref(value) when is_binary(value) and value != "", do: {:ok, value}

  defp normalize_ref({:mcp, server, tool})
       when (is_atom(server) or (is_binary(server) and server != "")) and
              (tool == :all or is_atom(tool) or (is_binary(tool) and tool != "")) do
    {:ok, {:mcp, server, tool}}
  end

  defp normalize_ref(other), do: {:error, {:invalid_tool_ref, other}}

  defp normalize_approval([]), do: {:ok, nil}
  defp normalize_approval([approval]), do: normalize_approval_value(approval)
  defp normalize_approval(_), do: {:error, {:invalid_option, :approval}}

  defp normalize_approval_value(value) when is_atom(value), do: {:ok, value}
  defp normalize_approval_value(value) when is_binary(value) and value != "", do: {:ok, value}
  defp normalize_approval_value(other), do: {:error, {:invalid_tool_approval, other}}
end
