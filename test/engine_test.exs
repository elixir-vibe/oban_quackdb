defmodule Oban.QuackDB.EngineTest do
  use ExUnit.Case, async: false

  import Ecto.Query

  alias Oban.{Config, Job}
  alias Oban.Engines.QuackDB, as: QuackEngine
  alias Oban.QuackDB.{TestRepo, TestWorker}

  setup do
    TestRepo.delete_all(Job)

    conf =
      Config.new(
        engine: QuackEngine,
        name: make_ref(),
        node: "quack-test",
        notifier: Oban.Notifiers.Isolated,
        peer: false,
        prefix: false,
        repo: TestRepo
      )

    {:ok, conf: conf}
  end

  test "executes jobs through an Oban supervision tree" do
    name = Module.concat(__MODULE__, Runtime)
    Application.put_env(:oban_quackdb, :test_pid, self())

    start_supervised!(
      {Oban,
       engine: QuackEngine,
       name: name,
       notifier: Oban.Notifiers.Isolated,
       peer: Oban.Peers.Isolated,
       plugins: [],
       prefix: false,
       queues: [default: 1],
       repo: TestRepo,
       stage_interval: 50}
    )

    assert {:ok, job} = Oban.insert(name, TestWorker.new(%{ref: 1}, queue: :default))
    assert_receive {:performed, 1}, 2_000

    assert eventually(fn ->
             match?(%Job{state: "completed"}, TestRepo.get(Job, job.id))
           end)
  end

  test "inserts regular, bulk, and unique jobs", %{conf: conf} do
    assert {:ok, %Job{id: first_id, args: %{id: 1}}} =
             QuackEngine.insert_job(conf, job(%{id: 1}), [])

    changesets = [job(%{id: 2}), job(%{id: 3})]

    assert [%Job{id: second_id}, %Job{id: third_id}] =
             QuackEngine.insert_all_jobs(conf, changesets, [])

    assert [first_id, second_id, third_id] |> Enum.uniq() |> Enum.count() == 3

    unique = [period: :infinity, fields: [:worker, :args]]

    assert {:ok, %Job{id: unique_id, conflict?: false}} =
             QuackEngine.insert_job(conf, job(%{id: 4}, unique: unique), [])

    assert {:ok, %Job{id: ^unique_id, conflict?: true}} =
             QuackEngine.insert_job(conf, job(%{id: 4}, unique: unique), [])

    keyed_unique = [period: :infinity, fields: [:worker, :args], keys: [:id]]

    assert {:ok, %Job{id: keyed_id}} =
             QuackEngine.insert_job(
               conf,
               job(%{id: 5, version: 1}, unique: keyed_unique),
               []
             )

    assert {:ok, %Job{id: ^keyed_id, conflict?: true}} =
             QuackEngine.insert_job(
               conf,
               job(%{id: 5, version: 2}, unique: keyed_unique, replace: [:args]),
               []
             )

    assert %Job{args: %{"id" => 5, "version" => 2}} = TestRepo.get!(Job, keyed_id)
    assert TestRepo.aggregate(Job, :count) == 5
  end

  test "stages, fetches, completes, and records errors", %{conf: conf} do
    scheduled_at = DateTime.add(DateTime.utc_now(), -10)

    assert {:ok, scheduled} =
             QuackEngine.insert_job(
               conf,
               job(%{id: 1}, state: "scheduled", scheduled_at: scheduled_at),
               []
             )

    assert {:ok, [%{id: staged_id, state: "scheduled"}]} =
             QuackEngine.stage_jobs(conf, Job, limit: 10)

    assert staged_id == scheduled.id
    assert {:ok, meta} = QuackEngine.init(conf, limit: 1, queue: "default")

    assert {:ok, {meta, [%Job{state: "executing", attempt: 1} = executing]}} =
             QuackEngine.fetch_jobs(conf, meta, %{})

    assert :ok = QuackEngine.complete_job(conf, executing)
    assert %Job{state: "completed", completed_at: %DateTime{}} = TestRepo.get!(Job, executing.id)

    assert {:ok, _inserted} = QuackEngine.insert_job(conf, job(%{id: 2}), [])
    assert {:ok, {_meta, [failed]}} = QuackEngine.fetch_jobs(conf, meta, %{})

    failed = %{
      failed
      | unsaved_error: %{
          kind: :error,
          reason: RuntimeError.exception("boom"),
          stacktrace: []
        }
    }

    assert :ok = QuackEngine.error_job(conf, failed, 30)

    assert %Job{state: "retryable", errors: [%{"attempt" => 1, "error" => error}]} =
             TestRepo.get!(Job, failed.id)

    assert error =~ "boom"
  end

  test "checks availability and handles individual lifecycle callbacks", %{conf: conf} do
    assert {:ok, inserted} = QuackEngine.insert_job(conf, job(%{id: 1}), [])
    assert {:ok, ["default"]} = QuackEngine.check_available(conf)

    assert {:ok, meta} = QuackEngine.init(conf, limit: 1, queue: "default")
    assert {:ok, {_meta, [executing]}} = QuackEngine.fetch_jobs(conf, meta, %{})

    failed = %{
      executing
      | unsaved_error: %{
          kind: :error,
          reason: RuntimeError.exception("discarded"),
          stacktrace: []
        }
    }

    assert :ok = QuackEngine.discard_job(conf, failed)

    assert %Job{state: "discarded", errors: [%{"error" => error}]} =
             TestRepo.get!(Job, inserted.id)

    assert error =~ "discarded"

    assert {:ok, mutable} = QuackEngine.insert_job(conf, job(%{id: 2}), [])
    assert :ok = QuackEngine.snooze_job(conf, mutable, 30)
    assert %Job{state: "scheduled", max_attempts: 21} = TestRepo.get!(Job, mutable.id)

    assert :ok = QuackEngine.retry_job(conf, mutable)
    available = TestRepo.get!(Job, mutable.id)
    assert available.state == "available"

    assert {:ok, updated} =
             QuackEngine.update_job(conf, available, %{priority: 5, tags: ["duck"]})

    assert %{priority: 5, tags: ["duck"]} = updated

    TestRepo.update_all(where(Job, [j], j.id == ^mutable.id), set: [state: "executing"])

    assert {:error, :locked_or_not_found} =
             QuackEngine.update_job(conf, mutable, %{priority: 1})

    TestRepo.update_all(where(Job, [j], j.id == ^mutable.id), set: [state: "scheduled"])

    assert :ok = QuackEngine.cancel_job(conf, mutable)
    assert %Job{state: "cancelled"} = TestRepo.get!(Job, mutable.id)

    assert :ok = QuackEngine.delete_job(conf, TestRepo.get!(Job, mutable.id))
    refute TestRepo.get(Job, mutable.id)
  end

  test "claims jobs once across concurrent producers", %{conf: conf} do
    changesets = for id <- 1..10, do: job(%{id: id})
    jobs = QuackEngine.insert_all_jobs(conf, changesets, [])
    assert Enum.count(jobs) == 10

    assert {:ok, first_meta} = QuackEngine.init(conf, limit: 5, queue: "default")
    assert {:ok, second_meta} = QuackEngine.init(conf, limit: 5, queue: "default")

    parent = self()

    tasks =
      for meta <- [first_meta, second_meta] do
        Task.async(fn ->
          send(parent, {:ready, self()})

          receive do
            :fetch -> QuackEngine.fetch_jobs(conf, meta, %{})
          end
        end)
      end

    pids =
      for _ <- tasks do
        assert_receive {:ready, pid}
        pid
      end

    Enum.each(pids, &send(&1, :fetch))

    claimed =
      tasks
      |> Task.await_many(10_000)
      |> Enum.flat_map(fn {:ok, {_meta, jobs}} -> jobs end)

    assert Enum.count(claimed) == 10
    assert claimed |> Enum.map(& &1.id) |> Enum.uniq() |> Enum.count() == 10
  end

  test "serializes concurrent unique inserts", %{conf: conf} do
    parent = self()
    unique = [period: :infinity, fields: [:worker, :args]]

    tasks =
      for _ <- 1..2 do
        Task.async(fn ->
          send(parent, {:ready, self()})

          receive do
            :insert ->
              QuackEngine.insert_job(conf, job(%{id: 1}, unique: unique), expected_retry: 20)
          end
        end)
      end

    pids =
      for _ <- tasks do
        assert_receive {:ready, pid}
        pid
      end

    Enum.each(pids, &send(&1, :insert))

    assert [{:ok, first}, {:ok, second}] = Task.await_many(tasks, 10_000)
    assert first.id == second.id
    assert Enum.sort([first.conflict?, second.conflict?]) == [false, true]
    assert TestRepo.aggregate(Job, :count) == 1
  end

  test "fails explicitly when the uniqueness lock is missing", %{conf: conf} do
    TestRepo.query!("DELETE FROM oban_locks WHERE name = 'unique'")

    try do
      assert_raise RuntimeError, ~r/missing QuackDB uniqueness lock/, fn ->
        QuackEngine.insert_job(conf, job(%{id: 1}, unique: [period: :infinity]), [])
      end
    after
      TestRepo.query!("INSERT INTO oban_locks (name) VALUES ('unique') ON CONFLICT DO NOTHING")
    end
  end

  test "cancels, retries, deletes, prunes, and rescues jobs", %{conf: conf} do
    jobs =
      for {id, state} <- [{1, "available"}, {2, "completed"}, {3, "executing"}] do
        {:ok, job} = QuackEngine.insert_job(conf, job(%{id: id}, state: state), [])
        job
      end

    [available, completed, executing] = jobs

    assert {:ok, [%{id: available_id, state: "available"}]} =
             QuackEngine.cancel_all_jobs(conf, where(Job, [j], j.id == ^available.id))

    assert available_id == available.id
    assert :ok = QuackEngine.retry_job(conf, TestRepo.get!(Job, available.id))
    assert %Job{state: "available"} = TestRepo.get!(Job, available.id)

    assert {:ok, [%{id: completed_id}]} =
             QuackEngine.delete_all_jobs(conf, where(Job, [j], j.id == ^completed.id))

    assert completed_id == completed.id
    refute TestRepo.get(Job, completed.id)

    old = DateTime.add(DateTime.utc_now(), -120)

    TestRepo.update_all(
      where(Job, [j], j.id == ^executing.id),
      set: [attempted_at: old, attempt: 1, max_attempts: 2]
    )

    assert {:ok, [%{id: executing_id, state: "available"}]} =
             QuackEngine.rescue_jobs(conf, Job, rescue_after: 60_000)

    assert executing_id == executing.id

    TestRepo.update_all(
      where(Job, [j], j.id == ^available.id),
      set: [state: "completed", completed_at: old]
    )

    assert {:ok, [%{id: pruned_id}]} = QuackEngine.prune_jobs(conf, Job, max_age: 60, limit: 10)
    assert pruned_id == available.id
    refute TestRepo.get(Job, available.id)
  end

  defp job(args, opts \\ []) do
    Job.new(args, Keyword.merge([worker: "QuackWorker", queue: "default"], opts))
  end

  defp eventually(fun, attempts \\ 20)
  defp eventually(fun, 0), do: fun.()

  defp eventually(fun, attempts) do
    if fun.() do
      true
    else
      Process.sleep(25)
      eventually(fun, attempts - 1)
    end
  end
end
