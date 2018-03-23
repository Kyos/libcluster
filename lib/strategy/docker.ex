defmodule Cluster.Strategy.Docker do
  @moduledoc """
  This clustering strategy works by loading all endpoints in the docker api that matches
  the configured label. It will fetch the addresses of all endpoints with
  that label and attempt to connect. It will continually monitor and update its
  connections every 5s.

  This can also be used to have an automatic clustering with docker-compose scale, if
  you specifiy the right labels (as shown on the configuration example below).

  In order for your endpoints to be found they should be returned when you run:

  `docker ps --filter="label=labelName=labelValue"`

  The easiest way to make this works with docker-compose is to specify this :

  ```
  # vm.args
  -sname app
  ```

  (in an app running as a Distillery release).

  An example configuration is below:

      config :libcluster,
        topologies: [
          docker_example: [
            strategy: #{__MODULE__},
            config: [
              mode: :dns,
              docker_node_basename: "app",
              docker_endpoint: "http://127.0.0.1:2375",
              label: [
                "com.docker.compose.project": "downloads",
                "com.docker.compose.service": "erlang",
              ],
              polling_interval: 10_000]]]

  """
  use GenServer
  use Cluster.Strategy
  import Cluster.Logger

  alias Cluster.Strategy.State

  @default_polling_interval 5_000
  @default_docker_endpoint "http://127.0.0.1:2375"
  @docker_endpoint_path "/containers/json"

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)
  def init(opts) do
    state = %State{
      topology: Keyword.fetch!(opts, :topology),
      connect: Keyword.fetch!(opts, :connect),
      disconnect: Keyword.fetch!(opts, :disconnect),
      list_nodes: Keyword.fetch!(opts, :list_nodes),
      config: Keyword.fetch!(opts, :config),
      meta: MapSet.new([])
    }
    {:ok, load(state)}
  end

  def handle_info(:timeout, state) do
    handle_info(:load, state)
  end
  def handle_info(:load, %State{} = state) do
    {:noreply, load(state)}
  end
  def handle_info(_, state) do
    {:noreply, state}
  end

  defp load(%State{topology: topology, connect: connect, disconnect: disconnect, list_nodes: list_nodes} = state) do
    new_nodelist = MapSet.new(get_nodes(state))
    added        = MapSet.difference(new_nodelist, state.meta)
    removed      = MapSet.difference(state.meta, new_nodelist)
    new_nodelist =
      case Cluster.Strategy.disconnect_nodes(topology, disconnect, list_nodes, MapSet.to_list(removed)) do
        :ok ->
          new_nodelist
        {:error, bad_nodes} ->
          # Add back the nodes which should have been removed, but which couldn't be for some reason
          Enum.reduce(bad_nodes, new_nodelist, fn {n, _}, acc ->
            MapSet.put(acc, n)
          end)
      end
    new_nodelist =
      case Cluster.Strategy.connect_nodes(topology, connect, list_nodes, MapSet.to_list(added)) do
        :ok ->
          new_nodelist
        {:error, bad_nodes} ->
          # Remove the nodes which should have been added, but couldn't be for some reason
          Enum.reduce(bad_nodes, new_nodelist, fn {n, _}, acc ->
            MapSet.delete(acc, n)
          end)
      end
    Process.send_after(self(), :load, Keyword.get(state.config, :polling_interval, @default_polling_interval))
    %{state | :meta => new_nodelist}
  end

  @spec get_nodes(State.t) :: [atom()]
  defp get_nodes(%State{topology: topology, config: config}) do
    docker_endpoint = Keyword.get(config, :docker_endpoint, @default_docker_endpoint)
    app_name = Keyword.fetch!(config, :docker_node_basename)
    label = Keyword.get(config, :label, [])

    case :httpc.request(:get, {'#{docker_endpoint <> @docker_endpoint_path}', []}, [], []) do
      {:ok, {{_version, 200, _status}, _headers, body}} ->
        containers = Poison.decode!(body) |> filter_containers(label)
        parse_response(Keyword.get(config, :mode, :ip), containers, app_name)
      {:ok, {{_version, code, status}, _headers, body}} ->
        warn topology, "cannot query docker (#{code} #{status}): #{inspect body}"
        []
      {:error, reason} ->
        error topology, "request to docker failed!: #{inspect reason}"
        []
    end

  end

  defp parse_response(:ip, resp, app_name) do
    Enum.reduce(resp, [], fn
      (%{"NetworkSettings" => %{"Networks" => network}}, acc) ->
        ip = network |> Map.values |> Enum.map(&Map.get(&1, "IPAddress"))
        name = :"#{app_name}@#{ip}}"
        cond do
          name === Node.self() -> acc
          true -> acc ++ [name]
        end
    end)
  end

  defp parse_response(:dns, resp, app_name) do
    Enum.reduce(resp, [], fn
      (%{"Id" => id}, acc) ->
        name = :"#{app_name}@#{String.slice(id, 0..11)}"
        cond do
          name === Node.self() -> acc
          true -> acc ++ [name]
        end
    end)
  end

  defp filter_containers(containers, label) when is_map(label) and map_size(label) > 0 do
    Enum.filter(containers, fn %{"Labels" => labels} -> is_container_valid(labels, label) end)
  end

  defp filter_containers(containers, _label), do: containers

  defp is_container_valid(container_label, label) do
    Enum.all?(label, fn {key, value} = x ->
      Enum.member?(container_label, x) && Map.fetch!(container_label, key) === value
    end)
  end

end
