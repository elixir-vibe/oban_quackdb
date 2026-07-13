defmodule Oban.QuackDB.TransactionTest do
  use ExUnit.Case, async: true

  alias Oban.QuackDB.Transaction

  defmodule ConflictRepo do
    def config, do: []

    def transaction(_fun, _opts) do
      attempt = Process.get({__MODULE__, :attempt}, 0) + 1
      Process.put({__MODULE__, :attempt}, attempt)

      if attempt < 3 do
        raise QuackDB.Error.new(:transaction_conflict, "conflict", retriable?: true)
      else
        {:ok, :retried}
      end
    end
  end

  defmodule RaisingRepo do
    def config, do: []
    def transaction(_fun, _opts), do: raise(QuackDB.Error.new(:server_error, "boom"))
  end

  test "retries classified QuackDB transaction conflicts" do
    conf =
      Oban.Config.new(
        engine: Oban.Engines.QuackDB,
        notifier: Oban.Notifiers.Isolated,
        peer: false,
        repo: ConflictRepo
      )

    assert {:ok, :retried} = Transaction.run(conf, fn -> :ok end, expected_delay: 0)
    assert Process.get({ConflictRepo, :attempt}) == 3
  end

  test "does not retry ordinary QuackDB errors" do
    conf =
      Oban.Config.new(
        engine: Oban.Engines.QuackDB,
        notifier: Oban.Notifiers.Isolated,
        peer: false,
        repo: RaisingRepo
      )

    assert_raise QuackDB.Error, "boom", fn ->
      Transaction.run(conf, fn -> :ok end, expected_delay: 0)
    end
  end
end
