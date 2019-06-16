defmodule Stacks.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  def start(_type, _args) do
    # List all child processes to be supervised
    children = [
      {Registry, keys: :unique, name: Stacks.Registry},
      {Registry, keys: :duplicate, name: Stacks.DockerEvents},
      Stacks.WatcherSupervisor,
      Stacks.Stack.ConfigLoader,
      Stacks.DockerEventHandler
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Stacks.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
