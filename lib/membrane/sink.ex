defmodule Membrane.Sink do
  @moduledoc """
  Module defining behaviour for sinks - elements consuming data.

  Behaviours for sinks are specified, besides this place, in modules
  `Membrane.Element.Base`,
  and `Membrane.WithInputPads`.

  Sink elements can define only input pads. Job of a usual sink is to receive some
  data on such pad and consume it (write to a soundcard, send through TCP etc.).
  If the pad works in pull mode, which is the most common case, then element is
  also responsible for requesting demands when it is able and willing to consume
  data (for more details, see `t:Membrane.Element.Action.demand_t/0`).
  Sinks, like all elements, can of course have multiple pads if needed to
  provide more complex solutions.
  """

  alias Membrane.{Buffer, Element, Pad}
  alias Element.CallbackContext

  @doc """
  Callback that is called when buffer should be written by the sink.

  By default calls `handle_write/4` for each buffer.

  For pads in pull mode it is called when buffers have been demanded (by returning
  `:demand` action from any callback).

  For pads in push mode it is invoked when buffers arrive.
  """
  @callback handle_write_list(
              pad :: Pad.ref_t(),
              buffers :: list(Buffer.t()),
              context :: CallbackContext.Write.t(),
              state :: Element.state_t()
            ) :: Membrane.Element.Base.callback_return_t()

  @doc """
  Callback that is called when buffer should be written by the sink. In contrast
  to `c:handle_write_list/4`, it is passed only a single buffer.

  Called by default implementation of `c:handle_write_list/4`.
  """
  @callback handle_write(
              pad :: Pad.ref_t(),
              buffer :: Buffer.t(),
              context :: CallbackContext.Write.t(),
              state :: Element.state_t()
            ) :: Membrane.Element.Base.callback_return_t()

  defmacro __using__(_) do
    quote location: :keep do
      use Membrane.Element.Base
      use Membrane.Element.WithInputPads
      @behaviour unquote(__MODULE__)

      @impl true
      def membrane_element_type, do: :sink

      @impl true
      def handle_write(_pad, _buffer, _context, state),
        do: {{:error, :handle_write_not_implemented}, state}

      @impl true
      def handle_write_list(pad, buffers, _context, state) do
        args_list = buffers |> Enum.map(&[pad, &1])
        {{:ok, split: {:handle_write, args_list}}, state}
      end

      defoverridable handle_write_list: 4,
                     handle_write: 4
    end
  end
end
