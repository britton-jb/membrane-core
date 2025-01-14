defmodule Membrane.Core.Parent.SpecController do
  @moduledoc false
  use Bunch
  use Membrane.Log, tags: :core

  alias Membrane.{Bin, Clock, CallbackError, Child, Element, ParentError, ParentSpec, Sync}
  alias Membrane.Core
  alias Core.{CallbackHandler, Message, Parent}
  alias Core.Parent.Link
  alias Bunch.Type

  require Bin
  require Element
  require Message
  require Membrane.PlaybackState

  @typep parsed_child_t :: %{name: Child.name_t(), module: module, options: Keyword.t()}

  @spec handle_spec(ParentSpec.t(), Parent.ChildrenModel.t()) ::
          Type.stateful_try_t([Child.name_t()], Parent.ChildrenModel.t())
  def handle_spec(spec, state) do
    %ParentSpec{
      children: children_spec,
      links: links,
      stream_sync: stream_sync,
      clock_provider: clock_provider
    } = spec

    debug("""
    Initializing spec
    children: #{inspect(children_spec)}
    links: #{inspect(links)}
    """)

    specific_spec_mod = specific_spec_module(state)

    parsed_children = children_spec |> parse_children()

    {:ok, state} = {parsed_children |> check_if_children_names_unique(state), state}

    syncs = setup_syncs(parsed_children, stream_sync)

    children = parsed_children |> start_children(state.clock_proxy, syncs)

    if state.playback.state == :playing do
      syncs |> MapSet.new(&elem(&1, 1)) |> Bunch.Enum.try_each(&Sync.activate/1)
    end

    {:ok, state} = children |> add_children(state)

    {:ok, state} = choose_clock(children, clock_provider, state)

    {:ok, links} = links |> Link.from_spec()

    {links, state} = links |> specific_spec_mod.resolve_links(state)
    {:ok, state} = links |> specific_spec_mod.link_children(state)
    {children_names, children_data} = children |> Enum.unzip()
    {:ok, state} = exec_handle_spec_started(children_names, state)

    children_data
    |> Enum.each(&change_playback_state(&1.pid, state.playback.state))

    {{:ok, children_names}, state}
  end

  defp specific_spec_module(%Core.Bin.State{}), do: Core.Bin.SpecController
  defp specific_spec_module(%Core.Pipeline.State{}), do: Core.Pipeline.SpecController

  defp setup_syncs(children, :sinks) do
    sinks =
      children |> Enum.filter(&(&1.module.membrane_element_type == :sink)) |> Enum.map(& &1.name)

    setup_syncs(children, [sinks])
  end

  defp setup_syncs(children, stream_sync) do
    children_names = children |> MapSet.new(& &1.name)
    all_to_sync = stream_sync |> List.flatten()

    withl dups: [] <- all_to_sync |> Bunch.Enum.duplicates(),
          unknown: [] <- all_to_sync |> Enum.reject(&(&1 in children_names)) do
      stream_sync
      |> Enum.flat_map(fn elements ->
        {:ok, sync} = Sync.start_link(empty_exit?: true)
        elements |> Enum.map(&{&1, sync})
      end)
      |> Map.new()
    else
      dups: dups ->
        raise ParentError,
              "Cannot apply sync - duplicate elements: #{dups |> Enum.join(", ")}"

      unknown: unknown ->
        raise ParentError,
              "Cannot apply sync - unknown elements: #{unknown |> Enum.join(", ")}"
    end
  end

  @spec change_playback_state(pid, Membrane.PlaybackState.t()) :: :ok
  defp change_playback_state(pid, new_state)
       when Membrane.PlaybackState.is_playback_state(new_state) do
    Message.send(pid, :change_playback_state, new_state)
    :ok
  end

  defguardp is_child_name(term)
            when is_atom(term) or
                   (is_tuple(term) and tuple_size(term) == 2 and is_atom(elem(term, 0)) and
                      is_integer(elem(term, 1)) and elem(term, 1) >= 0)

  @spec parse_children(ParentSpec.children_spec_t() | any) :: [parsed_child_t]
  defp parse_children(children) when is_map(children) or is_list(children),
    do: children |> Enum.map(&parse_child/1)

  defp parse_child({name, %module{} = options})
       when is_child_name(name) do
    %{name: name, module: module, options: options}
  end

  defp parse_child({name, module})
       when is_child_name(name) and is_atom(module) do
    options = module |> Bunch.Module.struct()
    %{name: name, module: module, options: options}
  end

  defp parse_child(config) do
    raise ParentError, "Invalid children config: #{inspect(config, pretty: true)}"
  end

  @spec check_if_children_names_unique([parsed_child_t], Parent.ChildrenModel.t()) ::
          Type.try_t()
  defp check_if_children_names_unique(children, state) do
    %{children: state_children} = state

    children
    |> Enum.map(& &1.name)
    |> Kernel.++(Map.keys(state_children))
    |> Bunch.Enum.duplicates()
    |> case do
      [] ->
        :ok

      duplicates ->
        raise ParentError, "Duplicated names in children specification: #{inspect(duplicates)}"
    end
  end

  @spec start_children(
          [parsed_child_t],
          parent_clock :: Clock.t(),
          syncs :: %{Child.name_t() => pid()}
        ) :: [Parent.ChildrenModel.child_t()]
  defp start_children(children, parent_clock, syncs) do
    debug("Starting children: #{inspect(children)}")

    children |> Enum.map(&start_child(&1, parent_clock, syncs))
  end

  @spec add_children([parsed_child_t()], Parent.ChildrenModel.t()) ::
          Type.stateful_try_t(Parent.ChildrenModel.t())
  defp add_children(children, state) do
    children
    |> Bunch.Enum.try_reduce(state, fn {name, data}, state ->
      state |> Parent.ChildrenModel.add_child(name, data)
    end)
  end

  defp start_child(%{name: name, module: module} = spec, parent_clock, syncs) do
    sync = syncs |> Map.get(name)

    case child_type(module) do
      :bin ->
        assert_no_sync!(spec, sync)
        start_child_bin(spec)

      :element ->
        start_child_element(spec, parent_clock, to_no_sync(sync))
    end
  end

  defp child_type(module) do
    if module |> Bunch.Module.check_behaviour(:membrane_bin?) do
      :bin
    else
      :element
    end
  end

  defp start_child_element(%{name: name, module: module, options: options}, parent_clock, sync) do
    debug("Pipeline: starting child: name: #{inspect(name)}, module: #{inspect(module)}")

    sync =
      case sync do
        nil -> Sync.no_sync()
        _ -> sync
      end

    with {:ok, pid} <-
           Core.Element.start_link(%{
             parent: self(),
             module: module,
             name: name,
             user_options: options,
             clock: parent_clock,
             sync: sync
           }),
         :ok <- Message.call(pid, :set_controlling_pid, self()),
         {:ok, %{clock: clock}} <- Message.call(pid, :handle_watcher, self()) do
      {name, %{pid: pid, clock: clock, sync: sync}}
    else
      {:error, reason} ->
        raise ParentError,
              "Cannot start child #{inspect(name)}, \
              reason: #{inspect(reason, pretty: true)}"
    end
  end

  defp start_child_bin(%{name: name, module: module, options: options}) do
    with {:ok, pid} <- Bin.start_link(name, module, options, []),
         :ok <- Message.call(pid, :set_controlling_pid, self()),
         {:ok, %{clock: clock}} <- Message.call(pid, :handle_watcher, self()) do
      {name, %{pid: pid, clock: clock, sync: Sync.no_sync()}}
    else
      {:error, reason} ->
        raise ParentError,
              "Cannot start child #{inspect(name)} module: #{inspect(module)}, \
              reason: #{inspect(reason, pretty: true)}"
    end
  end

  defp assert_no_sync!(_spec, _sync = nil) do
    :ok
  end

  defp assert_no_sync!(%{name: name}, _sync) do
    raise ParentError,
          "Cannot start child #{inspect(name)}, \
       reason: bin cannot be synced with other elements"
  end

  defp to_no_sync(nil), do: Sync.no_sync()
  defp to_no_sync(sync), do: sync

  defp exec_handle_spec_started(children_names, state) do
    action_handler =
      case state do
        %Core.Pipeline.State{} -> Core.Pipeline.ActionHandler
        %Core.Bin.State{} -> Core.Bin.ActionHandler
      end

    callback_res =
      CallbackHandler.exec_and_handle_callback(
        :handle_spec_started,
        action_handler,
        [children_names],
        state
      )

    case callback_res do
      {:ok, _} ->
        callback_res

      {{:error, reason}, _state} ->
        raise CallbackError,
          message: """
          Callback :handle_spec_started failed with reason: #{inspect(reason)}
          """
    end
  end

  @spec choose_clock(Parent.ChildrenModel.t()) :: {:ok, Parent.ChildrenModel.t()}
  def choose_clock(state) do
    choose_clock([], nil, state)
  end

  def choose_clock(children, provider, state) do
    cond do
      provider != nil -> get_clock_from_provider(children, provider)
      invalid_choice?(state) -> :no_provider
      true -> choose_clock_provider(children)
    end
    |> case do
      :no_provider ->
        {:ok, state}

      clock_provider ->
        Clock.proxy_for(state.clock_proxy, clock_provider.clock)
        {:ok, %{state | clock_provider: clock_provider}}
    end
  end

  defp invalid_choice?(state),
    do: state.clock_provider.clock != nil && state.clock_provider.choice == :manual

  defp get_clock_from_provider(children, provider) do
    children
    |> Enum.find(fn
      {^provider, _data} -> true
      _ -> false
    end)
    |> case do
      nil ->
        raise ParentError, "Unknown clock provider: #{inspect(provider)}"

      {^provider, %{clock: nil}} ->
        raise ParentError, "#{inspect(provider)} is not a clock provider"

      {^provider, %{clock: clock}} ->
        %{clock: clock, provider: provider, choice: :manual}
    end
  end

  defp choose_clock_provider(children) do
    case children |> Bunch.KVList.filter_by_values(& &1.clock) do
      [] ->
        %{clock: nil, provider: nil, choice: :auto}

      [{child, %{clock: clock}}] ->
        %{clock: clock, provider: child, choice: :auto}

      children ->
        raise ParentError, """
        Cannot choose clock for the pipeline, as multiple elements provide one, namely: #{
          children |> Keyword.keys() |> Enum.join(", ")
        }. Please explicitly select the clock by setting `ParentSpec.clock_provider` parameter.
        """
    end
  end
end
