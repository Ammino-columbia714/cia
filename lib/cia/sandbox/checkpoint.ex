defmodule CIA.Sandbox.Checkpoint do
  @moduledoc """
  A handle for a sandbox checkpoint.

  Checkpoint handles are returned by `CIA.Sandbox.checkpoint/2` and can be
  passed back to `CIA.Sandbox.restore/3`.

  For the common case, you do not need to construct this struct yourself.
  `CIA.Sandbox.restore/3` also accepts a checkpoint name directly:

      :ok = CIA.Sandbox.restore(sandbox, "project-baseline")

  `%CIA.Sandbox.Checkpoint{}` is the richer form used when you are round-
  tripping the value returned by `CIA.Sandbox.checkpoint/2` or when a provider
  needs a restore token that differs from CIA's public checkpoint name.

  `id` is CIA's public checkpoint identifier. `provider_ref` stores the
  provider-specific identifier used during restore when it differs from `id`.
  `metadata` contains provider-supplied checkpoint metadata when available.
  """

  defstruct [:id, :provider_ref, metadata: %{}]

  @type t :: %__MODULE__{
          id: String.t(),
          provider_ref: String.t(),
          metadata: map()
        }

  @doc """
  Builds a checkpoint handle.

  Use this when you want an explicit checkpoint value instead of a bare
  checkpoint name.
  """
  def new(id, provider_ref \\ nil, metadata \\ %{})
      when is_binary(id) and is_map(metadata) do
    %__MODULE__{id: id, provider_ref: provider_ref || id, metadata: metadata}
  end
end
