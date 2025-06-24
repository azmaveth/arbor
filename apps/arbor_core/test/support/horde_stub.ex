defmodule Arbor.Core.Test.HordeStub do
  @moduledoc """
  In-memory CRDT stub for fast unit testing.
  Simulates Horde behavior without distributed overhead.

  This module provides a process-based stub that mimics the APIs of
  `Horde.Registry` and `Horde.DynamicSupervisor` for use in unit
  and integration tests where actual distributed behavior is not required.

  It uses an `Agent` to maintain the state of registered processes and
  supervised children, allowing for fast and isolated testing of components
  that interact with Horde.

  ## Usage

  In your `test_helper.exs`, you can start this stub:

      {:ok, _} = Arbor.Core.Test.HordeStub.start_link([])

  Then, in your tests, you can use this module directly where you would
  normally use `Horde.Registry` or `Horde.DynamicSupervisor`. Remember to
  clean up state between tests if necessary:

      setup do
        Arbor.Core.Test.HordeStub.reset()
        :ok
      end
  """

  use Agent

  #
  # Public API
  #

  @doc """
  Starts the HordeStub agent.
  """
  def start_link(_opts) do
    Agent.start_link(fn -> initial_state() end, name: __MODULE__)
  end

  @doc """
  Resets the stub to its initial state. Useful for cleaning up between tests.
  """
  def reset() do
    Agent.update(__MODULE__, fn _ -> initial_state() end)
  end

  #
  # Horde.Registry API Mock
  #

  @doc """
  Mocks `Horde.Registry.register/3`.
  """
  def register(registry_name, key, value) do
    caller = self()

    Agent.update(__MODULE__, fn state ->
      put_in(state, [:registry, registry_name, key], {caller, value})
    end)

    :ok
  end

  @doc """
  Mocks `Horde.Registry.lookup/2`. Returns a list with one `{pid, value}` tuple if found.
  """
  def lookup(registry_name, key) do
    Agent.get(__MODULE__, fn state ->
      get_in(state, [:registry, registry_name, key])
    end)
    |> case do
      nil -> []
      {_pid, _value} = val -> [val]
    end
  end

  @doc """
  Mocks `Horde.Registry.unregister/2`.
  """
  def unregister(registry_name, key) do
    Agent.get_and_update(__MODULE__, fn state ->
      {_popped, new_state} = pop_in(state, [:registry, registry_name, key])
      {:ok, new_state}
    end)
  end

  #
  # Horde.DynamicSupervisor API Mock
  #

  @doc """
  Mocks `Horde.DynamicSupervisor.start_child/2`.
  """
  def start_child(supervisor_name, child_spec) do
    case start_spec(child_spec) do
      {:ok, pid} = result ->
        add_child_pid(supervisor_name, pid)
        result

      {:ok, pid, _info} = result ->
        add_child_pid(supervisor_name, pid)
        result

      {:error, _} = error ->
        error
    end
  end

  @doc """
  Mocks `Horde.DynamicSupervisor.terminate_child/2`.
  """
  def terminate_child(supervisor_name, pid) do
    {existed, _state} =
      Agent.get_and_update(__MODULE__, fn state ->
        children = get_in(state, [:supervisor_children, supervisor_name])

        if children && MapSet.member?(children, pid) do
          new_children = MapSet.delete(children, pid)
          new_state = put_in(state, [:supervisor_children, supervisor_name], new_children)
          {true, new_state}
        else
          {false, state}
        end
      end)

    if existed do
      if Process.alive?(pid) do
        ref = Process.monitor(pid)
        Process.exit(pid, :shutdown)

        receive do
          {:DOWN, ^ref, _, _, _} -> :ok
        after
          1000 -> Process.exit(pid, :kill)
        end
      end

      :ok
    else
      {:error, :not_found}
    end
  end

  @doc """
  Mocks `Horde.DynamicSupervisor.children/1`.
  """
  def children(supervisor_name) do
    Agent.get(__MODULE__, fn state ->
      get_in(state, [:supervisor_children, supervisor_name]) || MapSet.new()
    end)
    |> MapSet.to_list()
  end

  #
  # Private Functions
  #

  defp initial_state, do: %{registry: %{}, supervisor_children: %{}}

  defp start_spec(child_spec) do
    case child_spec do
      {m, a} -> apply(m, :start_link, a)
      m when is_atom(m) -> m.start_link()
      %{start: {m, f, a}} -> apply(m, f, a)
    end
  end

  defp add_child_pid(supervisor_name, pid) do
    Agent.update(__MODULE__, fn state ->
      update_in(state, [:supervisor_children, supervisor_name], fn
        nil -> MapSet.new([pid])
        set -> MapSet.put(set, pid)
      end)
    end)
  end
end
