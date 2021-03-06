defmodule Staxx.Instance do
  @moduledoc """
  Module is responsible for aggregation of testchain + stacks functions in one place.
  It handles and manages starting testchain/stacks in correct order and does input validation.
  """

  require Logger

  alias Staxx.Docker
  alias Staxx.Docker.Container
  alias Staxx.Testchain
  alias Staxx.Testchain.Helper
  alias Staxx.Instance.DynamicSupervisor, as: InstancesDynamicSupervisor
  alias Staxx.Instance.Supervisor, as: InstanceSupervisor
  alias Staxx.Instance.Stack
  alias Staxx.Instance.Stack.ConfigLoader

  @typedoc """
  Instance ID - binary string consist of numbers.
  """
  @type id() :: binary

  # Hardcoded testchain "stack" key. 
  @testchain_key "testchain"

  @doc """
  Get predefined Testchain "stack" config anme.
  """
  @spec testchain_key() :: binary
  def testchain_key(), do: @testchain_key

  @doc """
  Starts new instance using given configuration.
  """
  @spec start(map, binary) :: {:ok, binary} | {:error, term}
  def start(params, email \\ "")

  def start(%{@testchain_key => %{"config" => %{"id" => id}}} = params, email) do
    stacks = Map.drop(params, [@testchain_key])

    Logger.debug(fn ->
      """
      Starting instance with existing testchain #{id}
      Stack Configs:
      #{inspect(stacks, pretty: true)}
      """
    end)

    start(id, id, stacks, email)
  end

  def start(%{@testchain_key => %{"config" => config}} = params, email) do
    chain_config =
      config
      |> Helper.config_from_payload()
      |> Helper.generate_id!()

    stacks = Map.drop(params, [@testchain_key])

    Logger.debug(fn ->
      """
      Starting instance with new testchain
      Testchain configuration:
      #{inspect(chain_config, pretty: true)}

      Stack Configs:
      #{inspect(stacks, pretty: true)}
      """
    end)

    start(chain_config.id, chain_config, stacks, email)
  end

  def start(_, _),
    do: {:error, "wrong testchain config"}

  @doc """
  Start supervision tree for new instance
  """
  @spec start(binary, binary | map, map, binary) :: {:ok, Testchain.evm_id()} | {:error, term}
  def start(id, chain_config_or_id, stacks, email \\ "") when is_binary(id) do
    stack_names = get_stack_names(stacks)
    Logger.debug("Starting new instance with stacks: #{inspect(stack_names)}")

    # Binding email to chain configuration
    chain_config_or_id =
      chain_config_or_id
      |> case do
        config when is_map(config) ->
          Map.put(config, :email, email)

        id ->
          id
      end

    with :ok <- validate_stacks(stack_names),
         {:ok, pid} <-
           InstancesDynamicSupervisor.start_instance({id, chain_config_or_id, stacks}) do
      Logger.debug("Instance #{id}: Started supervisor tree #{inspect(pid)}")

      {:ok, id}
    else
      {:error, err} ->
        Logger.error("Failed to start instance: #{inspect(err)}")
        {:error, err}

      err ->
        Logger.error("Failed to start instance: #{inspect(err)}")
        {:error, err}
    end
  end

  @doc """
  Spawns new stack service.
  Helpful for dynamically starting new stacks for existing instance that already running.
  """
  @spec start_stack(id(), binary) :: DynamicSupervisor.on_start_child()
  def start_stack(instance_id, stack_name),
    do: InstanceSupervisor.start_stack(instance_id, stack_name)

  @doc """
  Stops stack in runnint instance.
  Will terminate all containers/resources binded to stack.
  """
  @spec stop_stack(id(), binary) :: :ok
  def stop_stack(instance_id, stack_name),
    do: Stack.stop(instance_id, stack_name)

  @doc """
  Stops supervision tree for instance with given ID
  """
  @spec stop(id()) :: :ok | {:error, term}
  def stop(id),
    do: InstancesDynamicSupervisor.stop_instance(id)

  @doc """
  Checks if given instance supervisor tree is alive
  """
  @spec alive?(id()) :: boolean
  def alive?(id) do
    id
    |> InstanceSupervisor.via_tuple()
    |> GenServer.whereis()
    |> case do
      nil ->
        false

      pid ->
        Process.alive?(pid)
    end
  end

  @doc """
  Starts new container for given `stack_name` in running instance `id`.
  """
  @spec start_container(binary, binary, Container.t()) :: {:ok, Container.t()} | {:error, term}
  def start_container(id, stack_name, %Container{name: ""} = container),
    do: start_container(id, stack_name, %Container{container | name: Docker.random_name()})

  def start_container(id, stack_name, %Container{network: ""} = container),
    do: start_container(id, stack_name, %Container{container | network: id})

  def start_container(id, stack_name, %Container{image: image} = container) do
    with {:alive, true} <- {:alive, Stack.alive?(id, stack_name)},
         {:image, true} <- {:image, ConfigLoader.has_image?(stack_name, image)},
         {:ok, _pid} <- Stack.start_container(id, stack_name, container) do
      {:ok, container}
    else
      {:alive, _} ->
        Logger.error("Instance #{id}: No active `stack` found to start new container")

        {:error, "failed to find instance with id #{id} & stack name: #{stack_name}"}

      {:image, _} ->
        Logger.error("Instance #{id}: No image #{image} is allowed for stack #{stack_name}")

        {:error, "#{image} image is not allowed for stack #{stack_name}"}

      err ->
        Logger.error(
          "Instance #{id}: failed to start container #{image} with err: #{inspect(err)}"
        )

        {:error, "failed to start image"}
    end
  end

  @doc """
  Get instance details by `id`.
  Will make calls to every stack and get it's information.
  """
  @spec info(binary) :: map | nil
  def info(id) do
    stacks_info =
      case alive?(id) do
        false ->
          []

        true ->
          id
          |> InstanceSupervisor.get_stack_manager_supervisor()
          |> Supervisor.which_children()
          |> Enum.filter(fn {_, _, _, mods} -> mods == [Stack] end)
          |> Enum.map(fn {_, pid, :worker, _} -> pid end)
          |> Enum.map(&Stack.info/1)
          |> List.flatten()
          |> Enum.reject(&is_nil/1)
      end

    # Adding EVM information
    id
    |> Testchain.info()
    |> case do
      nil ->
        stacks_info

      testchain_info ->
        stacks_info ++ [{@testchain_key, testchain_info}]
    end
    |> case do
      [] ->
        nil

      data ->
        Map.new(data)
    end
  end

  @doc """
  Load list of all available instances in system
  """
  @spec list(pos_integer | nil) :: [%{id: binary, stacks: %{required(binary) => map}}]
  def list(user_id) do
    # InstancesDynamicSupervisor
    # |> Supervisor.which_children()
    # |> Enum.map(fn {_, pid, :supervisor, _} -> pid end)
    # |> IO.inspect()

    user_id
    |> Testchain.list()
    |> Enum.reject(&is_nil/1)
    |> Enum.map(fn %{id: id} = details -> %{id: id, stacks: %{@testchain_key => details}} end)
  end

  @doc """
  Remove instance if it's not alive (testchain is stopped and no running containers).
  """
  @spec remove(binary) :: :ok | {:error, term}
  def remove(id) do
    id
    |> alive?()
    |> case do
      true ->
        {:error, "instance #{id} have to be stopped before removing"}

      false ->
        Testchain.remove(id)
    end
  end

  @doc """
  Force system to reload all stacks configs
  """
  @spec reload_config() :: :ok
  def reload_config(),
    do: ConfigLoader.reload()

  # Validate if all stacks are allowed to start
  defp validate_stacks([]), do: :ok

  defp validate_stacks(list) do
    result =
      list
      |> Enum.reject(&(&1 == @testchain_key))
      |> Enum.filter(fn stack_name -> ConfigLoader.get(stack_name) == nil end)

    case result do
      [] ->
        :ok

      list ->
        {:error, "Some stacks are not allowed to be started ! #{inspect(list)}"}
    end
  end

  # Get list of stack names that need to be started
  defp get_stack_names(params) when is_map(params) do
    params
    |> Map.keys()
    |> Enum.reject(&(&1 == @testchain_key))
    |> Enum.reject(&(&1 == ""))
  end
end
