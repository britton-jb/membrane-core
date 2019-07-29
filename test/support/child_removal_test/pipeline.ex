defmodule Membrane.Support.ChildRemovalTest.Pipeline do
  @moduledoc """
  Module used in tests for elements removing.

  This module allows to build two pipelines:
  * Simple one, with two filters
      source -- filter1 -- [input1] filter2 -- sink
  * Pipeline with two sources (if `extra_source` key is provided in opts).
      source -- filter1 -- [input1] filter2 -- sink
                                    [input2]
                                     /
                    extra_source ___/

  This pipeline also makes children aware of their names. They can reach their
  name by accessing field `ref` in their opts.

  Should be used along with `Membrane.Support.ChildRemovalTest.Pipeline` as they
  share names (i.e. input_pads: `input1` and `input2`) and exchanged messages' formats.
  """
  use Membrane.Pipeline

  alias Membrane.Support.ChildRemovalTest.Filter

  def remove_child(pid, child_name) do
    send(pid, {:remove_child, child_name})
  end

  @impl true
  def handle_init(opts) do
    children =
      [
        source: opts.source,
        filter1: opts.filter1,
        filter2: opts.filter2,
        sink: opts.sink
      ]
      |> maybe_add_extra_source(opts)
      |> add_refs()

    links =
      %{
        {:source, :output} => {:filter1, :input1, buffer: [preferred_size: 10]},
        {:filter1, :output} => {:filter2, :input1, buffer: [preferred_size: 10]},
        {:filter2, :output} => {:sink, :input, buffer: [preferred_size: 10]}
      }
      |> maybe_add_extra_source_link(opts)

    spec = %Pipeline.Spec{
      children: children,
      links: links
    }

    {{:ok, spec}, %{target: opts.target}}
  end

  @impl true
  def handle_other({:child_msg, name, msg}, state) do
    {{:ok, forward: {name, msg}}, state}
  end

  def handle_other({:remove_child, name}, state) do
    {{:ok, remove_child: name}, state}
  end

  @impl true
  def handle_prepared_to_playing(%{target: target} = state) do
    #send(target, {:playing, self()})
    {:ok, state}
  end

  @impl true
  def handle_prepared_to_stopped(%{target: t} = state) do
    send(t, :pipeline_stopped)
    {:ok, state}
  end

  def handle_notification(:playing, element, %{target: target} = state) do
    send(target, {:playing, element})
    {:ok, state}
  end
  def handle_notification(n, el, st) do
    {:ok, st}
  end

  defp maybe_add_extra_source(children, %{extra_source: source}),
    do: [{:extra_source, source} | children]

  defp maybe_add_extra_source(children, _), do: children

  defp maybe_add_extra_source_link(links, %{extra_source: _}) do
    Map.put(links, {:extra_source, :output}, {:filter2, :input2, buffer: [preferred_size: 10]})
  end

  defp maybe_add_extra_source_link(links, _) do
    links
  end

  defp add_refs(children) do
    children
    |> Enum.map(fn {name, opts_or_mod} -> {name, to_struct(opts_or_mod)} end)
    |> Enum.map(fn
      {name, %Filter{} = opts} -> {name, %{opts | ref: name}}
      e -> e
    end)
  end

  defp to_struct(%{} = opts), do: opts
  defp to_struct(module) when is_atom(module), do: struct(module)
end
