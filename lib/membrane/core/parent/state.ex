defmodule Membrane.Core.Parent.State do
  alias Membrane.Core.Parent.ChildrenController

  @type children_t :: %{ChildrenController.child_name_t() => pid}

  @type t :: Bin.State.t() | Pipeline.State.t()

  @spec add_child(t, ChildrenController.child_name_t(), pid) :: Type.stateful_try_t(t)
  def add_child(%{children: children} = state, child, pid) do
    if Map.has_key?(children, child) do
      {{:error, {:duplicate_child, child}}, state}
    else
      {:ok, %{state | children: children |> Map.put(child, pid)}}
    end
  end

  @spec get_child_pid(t, ChildrenController.child_name_t()) :: Type.try_t(pid)
  def get_child_pid(%{children: children}, child) do
    children[child] |> Bunch.error_if_nil({:unknown_child, child})
  end

  @spec pop_child(t, ChildrenController.child_name_t()) :: Type.stateful_try_t(pid, t)
  def pop_child(%{children: children} = state, child) do
    {pid, children} = children |> Map.pop(child)

    with {:ok, pid} <- pid |> Bunch.error_if_nil({:unknown_child, child}) do
      state = %{state | children: children}
      {{:ok, pid}, state}
    end
  end

  @spec get_children_names(t) :: [ChildrenController.child_name_t()]
  def get_children_names(%{children: children}) do
    children |> Map.keys()
  end

  @spec get_children(t) :: children_t
  def get_children(%{children: children}) do
    children
  end
end
