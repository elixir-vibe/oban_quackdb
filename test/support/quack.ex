defmodule Oban.QuackDB.TestServer do
  @moduledoc false

  alias Oban.QuackDB.{TestMigration, TestRepo}

  def start do
    path =
      Path.join(System.tmp_dir!(), "oban-quackdb-#{System.unique_integer([:positive])}.duckdb")

    port = available_port()
    token = "oban_quackdb_#{System.unique_integer([:positive])}"
    uri = "http://[::1]:#{port}"

    {:ok, server} =
      QuackDB.Server.start_link(
        duckdb: :managed,
        database: path,
        endpoint: "quack:localhost:#{port}",
        uri: uri,
        token: token,
        wait_timeout: 10_000
      )

    Application.put_env(:oban_quackdb, TestRepo,
      log: false,
      pool_size: System.schedulers_online(),
      stacktrace: true,
      uri: uri,
      token: token
    )

    {:ok, repo} = TestRepo.start_link()
    :ok = Ecto.Migrator.up(TestRepo, 1, TestMigration, log: false)

    {repo, server, path}
  end

  def stop({repo, server, path}) do
    if Process.alive?(repo), do: GenServer.stop(repo)
    if Process.alive?(server), do: GenServer.stop(server)

    File.rm(path)
    File.rm(path <> ".wal")
  end

  defp available_port do
    {:ok, socket} = :gen_tcp.listen(0, active: false)
    {:ok, port} = :inet.port(socket)
    :ok = :gen_tcp.close(socket)
    port
  end
end
