defmodule Membrane.Child do
  @moduledoc """
  Module that keeps track of types used by both elements and bins
  """
  alias Membrane.{Bin, Element}
  alias Membrane.Element.{Action, CallbackContext}

  @type name_t :: Element.name_t() | Bin.name_t()
  @type child_state_t :: Element.state_t() | Bin.state_t()

  @type callback_return_t ::
          {:ok | {:ok, [Action.t()]} | {:error, any}, child_state_t()} | {:error, any}

  @doc """
  Callback that is called when new pad has beed added to element. Executed
  ONLY for dynamic pads.
  """
  @callback handle_pad_added(
              pad :: Pad.ref_t(),
              context :: CallbackContext.PadAdded.t(),
              state :: child_state_t()
            ) :: callback_return_t

  @doc """
  Callback that is called when some pad of the element has beed removed. Executed
  ONLY for dynamic pads.
  """
  @callback handle_pad_removed(
              pad :: Pad.ref_t(),
              context :: CallbackContext.PadRemoved.t(),
              state :: child_state_t()
            ) :: callback_return_t

  @optional_callbacks handle_pad_added: 3,
                      handle_pad_removed: 3

  defmacro __using__(_opts) do
    quote do
      @behaviour unquote(__MODULE__)

      @impl true
      def handle_pad_added(_pad, _context, state), do: {:ok, state}

      @impl true
      def handle_pad_removed(_pad, _context, state), do: {:ok, state}

      defoverridable handle_pad_added: 3,
                     handle_pad_removed: 3
    end
  end
end
