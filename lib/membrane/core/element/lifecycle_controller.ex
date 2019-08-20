defmodule Membrane.Core.Element.LifecycleController do
  @moduledoc false
  # Module handling element initialization, termination, playback state changes
  # and similar stuff.

  alias Membrane.{Core, Element}
  alias Core.{CallbackHandler, Message, Playback, PadModel}
  alias Core.Element.{ActionHandler, PlaybackBuffer, State}
  alias Element.CallbackContext
  require CallbackContext.{Other, PlaybackChange}
  require Message
  require PadModel
  require Playback
  use Core.PlaybackHandler
  use Core.Element.Log
  use Bunch

  @doc """
  Performs initialization tasks and executes `handle_init` callback.
  """
  @spec handle_init(Element.options_t(), State.t()) :: State.stateful_try_t()
  def handle_init(options, %State{module: module} = state) do
    debug("Initializing element: #{inspect(module)}, options: #{inspect(options)}", state)

    with {:ok, state} <- exec_init_handler(module, options, state) do
      debug("Element initialized: #{inspect(module)}", state)
      {:ok, state}
    else
      {{:error, reason}, state} ->
        warn_error("Failed to initialize element", reason, state)
    end
  end

  @spec exec_init_handler(module, Element.options_t(), State.t()) :: State.stateful_try_t()
  defp exec_init_handler(module, options, state) do
    with {:ok, internal_state} <- module.handle_init(options) do
      {:ok, %State{state | internal_state: internal_state}}
    else
      {:error, reason} ->
        warn_error(
          """
          Module #{inspect(module)} handle_init callback returned an error
          """,
          {:handle_init, module, reason},
          state
        )

      other ->
        warn_error(
          """
          Module #{inspect(module)} handle_init callback returned invalid result:
          #{inspect(other)} instead of {:ok, state} or {:error, reason}
          """,
          {:invalid_callback_result, :handle_init, other},
          state
        )
    end
  end

  @doc """
  Performs shutdown checks and executes `handle_shutdown` callback.
  """
  @spec handle_shutdown(reason :: any, State.t()) :: {:ok, State.t()}
  def handle_shutdown(reason, state) do
    if state.terminating == :ready do
      debug("Terminating element, reason: #{inspect(reason)}", state)
    else
      warn(
        "Terminating element possibly not prepared for termination. Reason: #{inspect(reason)}",
        state
      )
    end

    %State{module: module, internal_state: internal_state} = state
    :ok = module.handle_shutdown(reason, internal_state)
    {:ok, state}
  end

  @spec handle_pipeline_down(reason :: any, State.t()) :: {:ok, State.t()}
  def handle_pipeline_down(reason, state) do
    if reason != :normal do
      warn_error(
        "Shutting down because of pipeline failure",
        {:pipeline_failure, reason: reason},
        state
      )
    end

    handle_shutdown(reason, state)
  end

  @doc """
  Handles custom messages incoming to element.
  """
  @spec handle_other(message :: any, State.t()) :: State.stateful_try_t()
  def handle_other(message, state) do
    ctx = CallbackContext.Other.from_state(state)

    CallbackHandler.exec_and_handle_callback(:handle_other, ActionHandler, [message, ctx], state)
    |> or_warn_error("Error while handling message")
  end

  @impl PlaybackHandler
  def handle_playback_state(old_playback_state, new_playback_state, state) do
    ctx = CallbackContext.PlaybackChange.from_state(state)
    callback = PlaybackHandler.state_change_callback(old_playback_state, new_playback_state)

    CallbackHandler.exec_and_handle_callback(
      callback,
      ActionHandler,
      [ctx],
      state
    )
  end

  @impl PlaybackHandler
  def handle_playback_state_changed(_old, :stopped, %State{terminating: true} = state),
    do: prepare_shutdown(state)

  @impl PlaybackHandler
  def handle_playback_state_changed(_old, _new, state) do
    PlaybackBuffer.eval(state)
  end

  @doc """
  Locks on stopped state and unlinks all element's pads.
  """
  @spec prepare_shutdown(State.t()) :: State.stateful_try_t()
  def prepare_shutdown(state) do
    if state.playback.state == :stopped and state.playback |> Playback.stable?() do
      {_result, state} = PlaybackHandler.lock_target_state(state)
      unlink(state.pads.data)
      Message.send(state.watcher, :shutdown_ready, state.name)
      {:ok, %State{state | terminating: :ready}}
    else
      state = %State{state | terminating: true}
      PlaybackHandler.change_and_lock_playback_state(:stopped, __MODULE__, state)
    end
  end

  defp unlink(pads_data) do
    pads_data
    |> Map.values()
    |> Enum.each(&Message.send(&1.pid, :handle_unlink, &1.other_ref))
  end
end
