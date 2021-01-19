defmodule Staxx.Testchain.EVM.Implementation.Geth do
  @moduledoc """
  Geth EVM implementation

  NOTE:
  Geth is running in dev mode and some configs are hardcoded by `geth`
  They are:
   - `chain_id` - 999
   - `gas_limit` - 6_283_185

  And another issue is that accounts will be created correctly
  but balance will be set only for `coinbase` account only (first account)
  """
  use Staxx.Testchain.EVM

  alias Staxx.Docker.Struct.SyncResult
  alias Staxx.Testchain.AccountStore
  alias Staxx.Testchain.EVM.Implementation.Geth.Genesis
  alias Staxx.Testchain.EVM.Implementation.Geth.AccountsCreator

  require Logger

  @doc """
  Path to geth account password file.
  This file have to be included in geth docker image by given path
  """
  @spec password_file() :: binary
  def password_file(),
    do: Application.get_env(:testchain, :account_password_file, "/app/account_password")

  @impl EVM
  def start(%Config{id: id, db_path: db_path} = config) do
    # We have to create accounts only if we don't have any already
    accounts =
      case AccountStore.exists?(db_path) do
        false ->
          Logger.debug("#{id}: Creating accounts")

          config
          |> Map.get(:accounts)
          |> AccountsCreator.create_accounts(db_path)
          |> store_accounts(db_path)

        true ->
          Logger.info("#{id} Path #{db_path} is not empty. New accounts would not be created.")
          {:ok, list} = load_accounts(db_path)
          list
      end

    Logger.debug("#{id}: Accounts: #{inspect(accounts)}")

    unless File.exists?(Path.join(db_path, "genesis.json")) do
      :ok = write_genesis(config, accounts)
      Logger.debug("#{id}: genesis.json file created")
    end

    # Checking for existing genesis block and init if not found
    # We switched to --dev with instamining feature so right now
    # we don't need to init chain from genesis.json

    unless File.dir?(db_path <> "/geth") do
      :ok = init_chain(db_path)
    end

    Logger.debug("#{id}: starting port with geth node")

    container = %Container{
      permanent: true,
      image: docker_image(),
      name: config.container_name,
      description: "#{id}: Geth EVM",
      cmd: build_cmd(config, accounts),
      ports: [internal_http_port(), internal_ws_port()],
      volumes: ["#{db_path}:#{db_path}"]
    }

    {:ok, container, %{}}
  end

  @impl EVM
  def pick_ports(ports, _) do
    {http_port, _} = Enum.find(ports, fn {_, port} -> port == internal_http_port() end)
    {ws_port, _} = Enum.find(ports, fn {_, port} -> port == internal_ws_port() end)
    {http_port, ws_port}
  end

  @impl EVM
  def docker_image(),
    do: Application.get_env(:testchain, :geth_docker_image)

  @doc """
  Bootstrap and initialize a new genesis block.

  It will run `geth init` command using `--datadir db_path`
  NOTE: this function will break `dev` mode and should not be used with it
  """
  @spec init_chain(binary) :: :ok | {:error, term()}
  def init_chain(db_path) do
    %Container{
      image: docker_image(),
      cmd: "--datadir #{db_path} init #{db_path}/genesis.json",
      volumes: ["#{db_path}:#{db_path}"]
    }
    |> Docker.run_sync()
    |> case do
      %SyncResult{status: 0} ->
        Logger.debug(fn -> "#{__MODULE__} geth initialized chain in #{db_path}" end)
        :ok

      %SyncResult{status: code, err: err} ->
        Logger.error(fn ->
          """
          #{__MODULE__}: Failed to run `geth init`. exited with code: #{code}.
          Error: #{inspect(err, pretty: true)}
          """
        end)

        {:error, :init_failed}
    end
  end

  #
  # Private functions
  #

  # Writing `genesis.json` file into defined `db_path`
  defp write_genesis(
         %Config{db_path: db_path, id: id} = config,
         accounts
       ) do
    Logger.debug("#{id}: Writring genesis file to `#{db_path}/genesis.json`")

    %Genesis{
      chain_id: Map.get(config, :network_id, 999),
      accounts: accounts,
      gas_limit: Map.get(config, :gas_limit),
      period: Map.get(config, :block_mine_time, 0)
    }
    |> Genesis.write(db_path)
  end

  # Build argument list for new geth node. See `Chain.EVM.Geth.start_node/1`
  defp build_cmd(
         %Config{
           db_path: db_path,
           network_id: network_id,
           gas_limit: gas_limit
         },
         accounts
       ) do
    cmd = [
      "--datadir #{db_path}",
      "--networkid #{network_id}",
      "--lightkdf",
      "--nodiscover",
      # Disabling network, node is private !
      "--maxpeers=0",
      "--port=0",
      "--nousb",
      "--ipcdisable",
      "--mine",
      "--minerthreads=1",
      "--rpc",
      "--rpcport #{internal_http_port()}",
      "--rpcapi admin,personal,eth,miner,debug,txpool,net,web3,db,ssh",
      "--rpcaddr=\"0.0.0.0\"",
      "--rpccorsdomain=\"*\"",
      "--rpcvhosts=\"*\"",
      "--ws",
      "--wsport #{internal_ws_port()}",
      "--wsorigins=\"*\"",
      "--gasprice=\"2000000000\"",
      "--targetgaslimit=\"#{gas_limit}\"",
      "--password=#{password_file()}",
      get_etherbase(accounts),
      get_unlock(accounts)
    ]

    # If version is greater than 1.8.17 need to add additional flag
    case Version.compare(get_version(), "1.8.27") do
      :gt ->
        cmd ++ ["--allow-insecure-unlock"]

      _ ->
        cmd
    end
    |> Enum.join(" ")
  end

  #####
  # List of functions generating CLI options
  #####

  # combine list of accounts to unlock `--unlock 0x....,0x.....`
  defp get_unlock([]), do: ""

  defp get_unlock(list) do
    res =
      list
      |> Enum.map(fn %Account{address: address} -> address end)
      |> Enum.join("\",\"")

    "--unlock=\"#{res}\""
  end

  # get etherbase account. it's just 1st address from list
  defp get_etherbase([]), do: ""

  defp get_etherbase([%Account{address: address} | _]),
    do: "--etherbase=#{address}"

  #####
  # End of list
  #####
end
