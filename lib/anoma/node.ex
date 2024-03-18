defmodule Anoma.Node do
  @moduledoc """
  I act as a registry for Anoma Nodes

  ## Required Arguments

    - `name` - name for this process
    - `snapshot_path` : [`atom()` | 0]
      - A snapshot location for the service (used in the worker)
    - `storage` : `Anoma.Storage.t()` - The Storage tables to use
    - `block_storage` - a location to store the blocks produced
  ## Optional Arguments

    - `jet` : `Nock.jettedness()` - how jetted the system should be
    - `old_storage` : `boolean` - states if the storage should be freshly made
       - by default it is `false`
  ## Registered names

  ### Created Tables
    - `storage.qualified`
    - `storage.order`
    - `block_storage`
  """

  use GenServer
  use TypedStruct
  alias Anoma.Node.Router
  alias __MODULE__

  typedstruct enforce: true do
    field(:router, Router.addr())
    field(:transport, Router.addr())
    field(:ordering, Router.addr())
    field(:executor, Router.addr())
    field(:executor_topic, Router.addr())
    field(:mempool, Router.addr())
    field(:mempool_topic, Router.addr())
    field(:pinger, Router.addr())
  end

  def start_link(args) do
    snap = args[:snapshot_path]
    storage = args[:storage]

    name = args[:name]
    args = Enum.filter(args, fn {k, _} -> k != :name end)
    resp = GenServer.start_link(__MODULE__, args, name: name)

    unless args[:old_storage] do
      Anoma.Storage.ensure_new(storage)
      Anoma.Storage.put_snapshot(storage, hd(snap))
    end

    resp
  end

  def init(args) do
    env = Map.merge(%Nock{}, Map.intersect(%Nock{}, args |> Enum.into(%{})))
    ping_name = Anoma.Node.Utility.append_name(args[:name], "_pinger")

    {:ok, router} = Router.start()

    {:ok, transport} = Router.start_transport(router)

    {:ok, ordering} =
      Router.start_engine(router, Anoma.Node.Storage.Ordering,
        table: args[:storage]
      )

    env = %{env | ordering: ordering}
    {:ok, executor_topic} = Router.new_topic(router)

    {:ok, executor} =
      Router.start_engine(router, Anoma.Node.Executor, {env, executor_topic})

    {:ok, mempool_topic} = Router.new_topic(router)

    {:ok, mempool} =
      Router.start_engine(router, Anoma.Node.Mempool,
        block_storage: args[:block_storage],
        ordering: ordering,
        executor: executor,
        topic: mempool_topic
      )

    {:ok, pinger} =
      Router.start_engine(router, Anoma.Node.Pinger,
        name: ping_name,
        mempool: mempool,
        time: args[:ping_time]
      )

    if Application.get_env(:anoma, :env) == :prod do
      Logger.configure(level: :all)
      Router.cast(transport, {:start_server, {:quic, "0.0.0.0", 24768}})
      IO.inspect(Anoma.Crypto.Id.print(router.id))
      IO.inspect(Anoma.Crypto.Id.print(transport.id))
      IO.inspect(Anoma.Crypto.Id.print(mempool.id))
      IO.inspect(Anoma.Crypto.Id.print(ordering.id))
    end

    {:ok,
     %Node{
       router: router,
       transport: transport,
       ordering: ordering,
       executor: executor,
       mempool: mempool,
       pinger: pinger,
       executor_topic: executor_topic,
       mempool_topic: mempool_topic
     }}
  end

  def state(nodes) do
    GenServer.call(nodes, :state)
  end

  def handle_call(:state, _from, state) do
    {:reply, state, state}
  end
end
