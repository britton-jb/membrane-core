defmodule Membrane.Testing.Source do
  @moduledoc """
  Testing Element for supplying data based on generator function passed through
  options.

  ## Example usage

  As mentioned earlier you can use this element in one of two ways, providing
  either a generator function or an `Enumerable.t`.

  ```
  %Sink{output: [0xA1, 0xB2, 0xC3, 0xD4]}
  ```

  In order to specify `Membrane.Testing.Sink` with generator function you need
  to provide initial state and function that matches `t:generator/0` type.
  ```
  generator_function = fn state, size ->
    #generate some buffers
    {actions, state + 1}
  end
  %Sink{output: {1, generator_function}}
  ```
  """

  use Membrane.Source
  alias Membrane.Buffer
  alias Membrane.Element.Action

  @type generator ::
          (state :: any(), buffers_cnt :: pos_integer -> {[Action.t()], state :: any()})

  def_output_pad :output, caps: :any

  def_options output: [
                spec: {initial_state :: any(), generator} | Enum.t(),
                default: {0, &__MODULE__.default_buf_gen/2},
                description: """
                If `output` is an enumerable with `Membrane.Payload.t()` then
                buffer containing those payloads will be sent through the
                `:output` pad and followed by `Membrane.Event.EndOfStream`.

                If `output` is a `{initial_state, function}` tuple then the
                the function will be invoked each time `handle_demand` is called.
                It is an action generator that takes two arguments.
                The first argument is the state that is initially set to
                `initial_state`. The second one defines the size of the demand.
                Such function should return `{actions, next_state}` where
                `actions` is a list of actions that will be returned from
                `handle_demand/4` and `next_state` is the value that will be
                used for the next call.
                """
              ]

  @impl true
  def handle_init(%__MODULE__{output: output} = opts) do
    opts = Map.from_struct(opts)

    case output do
      {initial_state, generator} when is_function(generator) ->
        {:ok, opts |> Map.merge(%{generator_state: initial_state, output: generator})}

      _enumerable_output ->
        {:ok, opts}
    end
  end

  @impl true
  def handle_demand(:output, size, :buffers, _ctx, state) do
    {actions, state} = get_actions(state, size)
    {{:ok, actions}, state}
  end

  @spec default_buf_gen(integer(), integer()) :: {[Action.t()], integer()}
  def default_buf_gen(generator_state, size) do
    buffers =
      generator_state..(size + generator_state - 1)
      |> Enum.map(fn generator_state ->
        %Buffer{payload: <<generator_state::16>>}
      end)

    action = [buffer: {:output, buffers}]
    {action, generator_state + size}
  end

  defp get_actions(%{generator_state: generator_state, output: actions_generator} = state, size)
       when is_function(actions_generator) do
    {actions, generator_state} = actions_generator.(generator_state, size)
    {actions, %{state | generator_state: generator_state}}
  end

  defp get_actions(%{output: output} = state, size) do
    {payloads, output} = Enum.split(output, size)
    buffers = Enum.map(payloads, &%Buffer{payload: &1})

    actions =
      case output do
        [] -> [buffer: {:output, buffers}, end_of_stream: :output]
        _ -> [buffer: {:output, buffers}]
      end

    {actions, %{state | output: output}}
  end
end
