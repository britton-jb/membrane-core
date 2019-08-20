defmodule Membrane.Parent.Action do
  alias Membrane.{Child, Notification, Spec}

  @moduledoc """
  Common types definitions for bin and element.
  """

  @typedoc """
  Action that sends a message to element identified by name.
  """
  @type forward_action_t :: {:forward, {Child.name_t(), Notification.t()}}

  @typedoc """
  Action that instantiates elements and links them according to `Membrane.Spec`.

  Children's playback state is changed to the current parent state.
  `c:handle_spec_started` callback is executed once it happens.
  """
  @type spec_action_t :: {:spec, Spec.t()}

  @typedoc """
  Action that stops, unlinks and removes specified child/children from their parent.
  """
  @type remove_child_action_t ::
          {:remove_child, Child.name_t() | [Child.name_t()]}

  @typedoc """
  Type describing actions that can be returned from parent callbacks.

  Returning actions is a way of pipeline/bin interaction with its elements and
  other parts of framework.
  """
  @type t :: forward_action_t | spec_action_t | remove_child_action_t
end
