defmodule Membrane.Element.ElementTest do
  use ExUnit.Case, async: true

  import Membrane.Testing.Assertions

  alias Membrane.Testing

  defmodule TestFilter do
    use Membrane.Filter

    def_input_pad :input, demand_unit: :buffers, caps: :any

    def_output_pad :output, caps: :any

    def_options target: [type: :pid]

    def assert_callback_called(name), do: assert_receive({:callback_called, ^name})

    def refute_callback_called(name), do: refute_receive({:callback_called, ^name})

    @impl true
    def handle_init(opts), do: {:ok, opts}

    @impl true
    def handle_start_of_stream(_pad, _context, state) do
      send(state.target, {:callback_called, :handle_start_of_stream})
      {:ok, state}
    end

    @impl true
    def handle_end_of_stream(_pad, _context, state) do
      send(state.target, {:callback_called, :handle_end_of_stream})
      {:ok, state}
    end

    @impl true
    def handle_event(_, _, _, state) do
      send(state.target, {:callback_called, :handle_event})
      {:ok, state}
    end

    @impl true
    def handle_demand(_, size, _, _ctx, state), do: {{:ok, demand: {:input, size}}, state}

    @impl true
    def handle_process(_pad, _buffer, _context, state), do: {:ok, state}
  end

  setup do
    {:ok, pipeline} =
      Testing.Pipeline.start_link(%Testing.Pipeline.Options{
        elements: [
          source: %Testing.Source{output: ['a', 'b', 'c']},
          filter: %TestFilter{target: self()},
          sink: Testing.Sink
        ]
      })

    on_exit(fn ->
      Testing.Pipeline.stop(pipeline)
    end)

    [pipeline: pipeline]
  end

  describe "Start of stream" do
    test "causes handle_start_of_stream/3 to be called", %{pipeline: pipeline} do
      Testing.Pipeline.play(pipeline)
      assert_pipeline_playback_changed(pipeline, _, :playing)

      TestFilter.assert_callback_called(:handle_start_of_stream)
    end

    test "does not trigger calling callback handle_event/3", %{pipeline: pipeline} do
      Testing.Pipeline.play(pipeline)
      assert_pipeline_playback_changed(pipeline, _, :playing)

      TestFilter.refute_callback_called(:handle_event)
    end

    test "causes handle_element_start_of_stream/3 to be called in pipeline", %{pipeline: pipeline} do
      Testing.Pipeline.play(pipeline)

      assert_start_of_stream(pipeline, :filter)
    end
  end

  describe "End of stream" do
    test "causes handle_end_of_stream/3 to be called", %{pipeline: pipeline} do
      Testing.Pipeline.play(pipeline)
      assert_pipeline_playback_changed(pipeline, _, :playing)

      TestFilter.assert_callback_called(:handle_end_of_stream)
    end

    test "does not trigger calling callback handle_event/3", %{pipeline: pipeline} do
      Testing.Pipeline.play(pipeline)
      assert_pipeline_playback_changed(pipeline, _, :playing)

      TestFilter.refute_callback_called(:handle_event)
    end

    test "causes handle_element_end_of_stream/3 to be called in pipeline", %{pipeline: pipeline} do
      Testing.Pipeline.play(pipeline)

      assert_end_of_stream(pipeline, :filter)
    end
  end
end
