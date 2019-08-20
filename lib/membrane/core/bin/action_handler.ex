defmodule Membrane.Core.Bin.ActionHandler do
  @moduledoc false
  use Membrane.Core.CallbackHandler
  use Membrane.Log, tags: :core

  alias Membrane.{Core, Spec}
  alias Core.{Parent, Message}
  alias Parent.ChildrenController
  alias Core.Bin.{State, SpecController}

  require Message

  @impl CallbackHandler
  def handle_action({:forward, {elementname, message}}, _cb, _params, state) do
    Parent.Action.handle_forward(elementname, message, state)
  end

  @impl CallbackHandler
  def handle_action({:spec, spec = %Spec{}}, _cb, _params, state) do
    with {{:ok, _children}, state} <- ChildrenController.handle_spec(SpecController, spec, state),
         do: {:ok, state}
  end

  @impl CallbackHandler
  def handle_action({:remove_child, children}, _cb, _params, state) do
    Parent.Action.handle_remove_child(children, state)
  end

  @impl CallbackHandler
  def handle_action({:notify, notification}, _cb, _params, state) do
    send_notification(notification, state)
  end

  @impl CallbackHandler
  def handle_action(action, callback, _params, state) do
    Parent.Action.handle_unknown_action(action, callback, state.module)
  end

  @spec send_notification(Notification.t(), State.t()) :: {:ok, State.t()}
  defp send_notification(notification, %State{watcher: nil} = state) do
    debug("Dropping notification #{inspect(notification)} as watcher is undefined", state)
    {:ok, state}
  end

  defp send_notification(notification, %State{watcher: watcher, name: name} = state) do
    debug("Sending notification #{inspect(notification)} (watcher: #{inspect(watcher)})", state)
    Message.send(watcher, :notification, [name, notification])
    {:ok, state}
  end
end
