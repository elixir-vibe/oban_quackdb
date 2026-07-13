defmodule Oban.QuackDB.TestRepo do
  @moduledoc false

  use Ecto.Repo,
    otp_app: :oban_quackdb,
    adapter: Ecto.Adapters.QuackDB
end

defmodule Oban.QuackDB.TestMigration do
  @moduledoc false

  use Ecto.Migration

  def up, do: Oban.Migrations.QuackDB.up()
  def down, do: Oban.Migrations.QuackDB.down()
end

defmodule Oban.QuackDB.TestWorker do
  @moduledoc false

  use Oban.Worker

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"ref" => ref}}) do
    send(Application.fetch_env!(:oban_quackdb, :test_pid), {:performed, ref})

    :ok
  end
end
