defmodule Oban.Engines.QuackDB do
  @moduledoc """
  An experimental engine for running Oban with DuckDB through QuackDB.

  QuackDB and DuckDB's Quack protocol are both experimental. This engine uses
  optimistic transaction retries for concurrent job claims and serializes
  unique inserts through the `oban_locks` table.

  Configure QuackDB with a persistent DuckDB database for durable job storage.
  The Reindexer plugin is PostgreSQL-specific and must not be enabled.

  ## Usage

  Start an `Oban` instance using the `QuackDB` engine:

      Oban.start_link(
        engine: Oban.Engines.QuackDB,
        queues: [default: 10],
        repo: MyApp.Repo
      )
  """

  @behaviour Oban.Engine

  import DateTime, only: [utc_now: 0]
  import Ecto.Query
  import QuackDB.Ecto.Analytics, only: [json_contains: 2]
  import QuackDB.Ecto.List, only: [append: 2]

  alias Ecto.Changeset
  alias Oban.{Config, Engine, Job, Repo}
  alias Oban.Engines.Basic
  alias Oban.QuackDB.Transaction

  @impl Engine
  def init(%Config{} = conf, opts) do
    if opts[:validate] do
      Basic.init(conf, opts)
    else
      validate_config!(conf)
      Basic.init(conf, opts)
    end
  end

  @impl Engine
  defdelegate put_meta(conf, meta, key, value), to: Basic

  @impl Engine
  defdelegate check_meta(conf, meta, running), to: Basic

  @impl Engine
  defdelegate refresh(conf, meta), to: Basic

  @impl Engine
  defdelegate shutdown(conf, meta), to: Basic

  @impl Engine
  def insert_job(%Config{} = conf, %Changeset{} = changeset, opts) do
    inst_opts = Keyword.take(opts, [:on_conflict, :timeout])

    case unique_query(changeset) do
      nil ->
        Repo.insert(conf, changeset, inst_opts)

      query ->
        insert_unique_job(conf, changeset, query, inst_opts, opts)
    end
  end

  @impl Engine
  defdelegate insert_all_jobs(conf, changesets, opts), to: Basic

  @impl Engine
  def fetch_jobs(_conf, %{paused: true} = meta, _running) do
    {:ok, {meta, []}}
  end

  def fetch_jobs(_conf, %{limit: limit} = meta, running) when map_size(running) >= limit do
    {:ok, {meta, []}}
  end

  def fetch_jobs(%Config{} = conf, meta, running) do
    demand = meta.limit - map_size(running)

    # QuackDB updates don't return rows. Mark claims with exact attempt metadata, then select those
    # rows back within the same retried transaction.
    Transaction.run(conf, fn ->
      attempted_at = utc_now()
      attempted_by = [meta.node, meta.uuid]

      ids =
        Job
        |> select([j], j.id)
        |> where([j], j.state == "available")
        |> where([j], j.queue == ^meta.queue)
        |> where([j], j.attempt < j.max_attempts)
        |> order_by([j], asc: j.priority, asc: j.scheduled_at, asc: j.id)
        |> limit(^demand)
        |> then(&Repo.all(conf, &1))

      if ids == [] do
        {meta, []}
      else
        query = where(Job, [j], j.id in ^ids and j.state == "available")

        Repo.update_all(conf, query,
          set: [state: "executing", attempted_at: attempted_at, attempted_by: attempted_by],
          inc: [attempt: 1]
        )

        jobs =
          Job
          |> where([j], j.id in ^ids and j.state == "executing")
          |> where([j], j.attempted_at == ^attempted_at and j.attempted_by == ^attempted_by)
          |> order_by([j], asc: j.priority, asc: j.scheduled_at, asc: j.id)
          |> then(&Repo.all(conf, &1))

        {meta, jobs}
      end
    end)
  end

  @impl Engine
  def stage_jobs(%Config{} = conf, queryable, opts) do
    limit = Keyword.fetch!(opts, :limit)

    Transaction.run(conf, fn ->
      jobs =
        queryable
        |> select([j], map(j, [:id, :queue, :state, :worker]))
        |> where([j], j.state in ~w(scheduled retryable))
        |> where([j], j.scheduled_at <= ^utc_now())
        |> order_by([j], desc: j.scheduled_at, desc: j.id)
        |> limit(^limit)
        |> then(&Repo.all(conf, &1))

      update_ids(conf, jobs,
        where: [state: ~w(scheduled retryable)],
        set: [state: "available"]
      )

      jobs
    end)
  end

  @impl Engine
  def prune_jobs(%Config{} = conf, queryable, opts) do
    max_age = Keyword.fetch!(opts, :max_age)
    limit = Keyword.fetch!(opts, :limit)
    time = DateTime.add(utc_now(), -max_age)

    Transaction.run(conf, fn ->
      jobs =
        queryable
        |> select([j], map(j, [:id, :queue, :state]))
        |> where(
          [j],
          (j.state == "completed" and j.completed_at < ^time) or
            (j.state == "cancelled" and j.cancelled_at < ^time) or
            (j.state == "discarded" and j.discarded_at < ^time)
        )
        |> limit(^limit)
        |> then(&Repo.all(conf, &1))

      delete_ids(conf, jobs)

      jobs
    end)
  end

  @impl Engine
  def rescue_jobs(%Config{} = conf, queryable, opts) do
    rescue_after = Keyword.fetch!(opts, :rescue_after)
    now = utc_now()
    cut = DateTime.add(now, -rescue_after, :millisecond)

    Transaction.run(conf, fn ->
      jobs =
        queryable
        |> where([j], j.state == "executing" and j.attempted_at < ^cut)
        |> select([j], map(j, [:attempt, :id, :max_attempts, :queue, :state]))
        |> then(&Repo.all(conf, &1))

      {available, discarded} = Enum.split_with(jobs, &(&1.attempt < &1.max_attempts))

      update_ids(conf, available, where: [state: ["executing"]], set: [state: "available"])

      update_ids(conf, discarded,
        where: [state: ["executing"]],
        set: [state: "discarded", discarded_at: now]
      )

      Enum.map(available, &%{&1 | state: "available"}) ++
        Enum.map(discarded, &%{&1 | state: "discarded"})
    end)
  end

  @impl Engine
  defdelegate check_available(conf), to: Basic

  @impl Engine
  defdelegate complete_job(conf, job), to: Basic

  @impl Engine
  defdelegate snooze_job(conf, job, seconds), to: Basic

  @impl Engine
  def discard_job(%Config{} = conf, %Job{} = job) do
    error = Job.format_attempt(job)

    query =
      Job
      |> where(id: ^job.id)
      |> update([j],
        set: [
          state: "discarded",
          discarded_at: ^utc_now(),
          errors: append(j.errors, type(^error, :map))
        ]
      )

    Repo.update_all(conf, query, [])

    :ok
  end

  @impl Engine
  def error_job(%Config{} = conf, %Job{} = job, seconds) do
    error = Job.format_attempt(job)

    query =
      Job
      |> where(id: ^job.id)
      |> update([j],
        set: [
          state: "retryable",
          scheduled_at: ^seconds_from_now(seconds),
          errors: append(j.errors, type(^error, :map))
        ]
      )

    Repo.update_all(conf, query, [])

    :ok
  end

  @impl Engine
  def cancel_job(%Config{} = conf, %Job{} = job) do
    query = where(Job, id: ^job.id)

    query =
      if is_map(job.unsaved_error) do
        error = Job.format_attempt(job)

        update(query, [j],
          set: [
            state: "cancelled",
            cancelled_at: ^utc_now(),
            errors: append(j.errors, type(^error, :map))
          ]
        )
      else
        query
        |> where([j], j.state not in ~w(cancelled completed discarded))
        |> update(set: [state: "cancelled", cancelled_at: ^utc_now()])
      end

    Repo.update_all(conf, query, [])

    :ok
  end

  @impl Engine
  def cancel_all_jobs(%Config{} = conf, queryable) do
    Transaction.run(conf, fn ->
      jobs =
        queryable
        |> where([j], j.state not in ~w(cancelled completed discarded))
        |> select([j], map(j, [:id, :queue, :state, :worker]))
        |> then(&Repo.all(conf, &1))

      update_ids(conf, jobs,
        where: [state: ~w(suspended scheduled available executing retryable)],
        set: [state: "cancelled", cancelled_at: utc_now()]
      )

      jobs
    end)
  end

  @impl Engine
  def delete_job(%Config{} = conf, %Job{id: id}) do
    delete_all_jobs(conf, where(Job, [j], j.id == ^id))

    :ok
  end

  @impl Engine
  def delete_all_jobs(%Config{} = conf, queryable) do
    Transaction.run(conf, fn ->
      jobs =
        queryable
        |> where([j], j.state != "executing")
        |> select([j], map(j, [:id, :queue, :state]))
        |> then(&Repo.all(conf, &1))

      delete_ids(conf, jobs)

      jobs
    end)
  end

  @impl Engine
  def retry_job(%Config{} = conf, %Job{id: id}) do
    retry_all_jobs(conf, where(Job, [j], j.id == ^id))

    :ok
  end

  @impl Engine
  def retry_all_jobs(%Config{} = conf, queryable) do
    Transaction.run(conf, fn ->
      jobs =
        queryable
        |> where([j], j.state not in ~w(available executing))
        |> select([j], map(j, [:id, :queue, :state, :worker]))
        |> then(&Repo.all(conf, &1))

      ids = Enum.map(jobs, & &1.id)

      if ids != [] do
        query =
          Job
          |> where([j], j.id in ^ids and j.state not in ~w(available executing))
          |> update([j],
            set: [
              state: "available",
              max_attempts: fragment("greatest(?, ? + 1)", j.max_attempts, j.attempt),
              scheduled_at: ^utc_now(),
              completed_at: nil,
              cancelled_at: nil,
              discarded_at: nil
            ]
          )

        Repo.update_all(conf, query, [])
      end

      jobs
    end)
  end

  @impl Engine
  def update_job(%Config{} = conf, %Job{id: id}, changes) when is_map(changes) do
    result =
      Transaction.run(conf, fn ->
        query = where(Job, [j], j.id == ^id and j.state != "executing")

        case Repo.one(conf, query) do
          nil -> {:error, :locked_or_not_found}
          job -> job |> Job.update(changes) |> then(&Repo.update(conf, &1))
        end
      end)

    case result do
      {:ok, result} -> result
      {:error, reason} -> {:error, reason}
    end
  end

  # Unique Insertion

  defp insert_unique_job(conf, changeset, query, inst_opts, opts) do
    repo_opts = Keyword.drop(opts, [:on_conflict, :timeout])
    fun = fn -> insert_unique(conf, changeset, query, inst_opts) end

    with {:ok, result} <- Transaction.run(conf, fun, repo_opts), do: result
  end

  defp insert_unique(conf, changeset, query, opts) do
    acquire_unique_lock!(conf)

    case Repo.one(conf, query) do
      nil ->
        Repo.insert(conf, changeset, opts)

      job ->
        with {:ok, job} <- resolve_conflict(conf, job, changeset, opts) do
          {:ok, %{job | conflict?: true}}
        end
    end
  end

  defp acquire_unique_lock!(conf) do
    # Concurrent DuckDB appends don't conflict. Updating a fixed row forces competing uniqueness
    # checks through the transaction retry loop before either insert can commit.
    query = from(lock in "oban_locks", where: lock.name == "unique")

    case Repo.update_all(conf, query, inc: [revision: 1]) do
      {1, nil} -> :ok
      _result -> raise "missing QuackDB uniqueness lock; run Oban migrations"
    end
  end

  defp unique_query(%{changes: %{unique: %{} = unique}} = changeset) do
    %{fields: fields, keys: keys, period: period, states: states, timestamp: timestamp} = unique

    keys = Enum.map(keys, &to_string/1)
    states = Enum.map(states, &to_string/1)
    dynamic = Enum.reduce(fields, true, &unique_field({changeset, &1, keys}, &2))

    Job
    |> where([j], j.state in ^states)
    |> since_period(period, timestamp)
    |> where(^dynamic)
    |> limit(1)
  end

  defp unique_query(_changeset), do: nil

  defp unique_field({changeset, field, keys}, acc) when field in [:args, :meta] do
    value = unique_map_values(changeset, field, keys)

    cond do
      value == %{} ->
        dynamic([j], json_contains(type(^value, :map), field(j, ^field)) and ^acc)

      keys == [] ->
        dynamic(
          [j],
          json_contains(field(j, ^field), type(^value, :map)) and
            json_contains(type(^value, :map), field(j, ^field)) and ^acc
        )

      true ->
        dynamic([j], json_contains(field(j, ^field), type(^value, :map)) and ^acc)
    end
  end

  defp unique_field({changeset, field, _keys}, acc) do
    value = Changeset.get_field(changeset, field)

    dynamic([j], field(j, ^field) == ^value and ^acc)
  end

  defp since_period(query, :infinity, _timestamp), do: query

  defp since_period(query, period, timestamp) do
    where(query, [j], field(j, ^timestamp) >= ^seconds_from_now(-period))
  end

  defp unique_map_values(changeset, field, []) do
    Changeset.get_field(changeset, field)
  end

  defp unique_map_values(changeset, field, keys) do
    changeset
    |> Changeset.get_field(field)
    |> Map.new(fn {key, value} -> {to_string(key), value} end)
    |> Map.take(keys)
  end

  defp resolve_conflict(conf, job, changeset, opts) do
    case Changeset.fetch_change(changeset, :replace) do
      {:ok, replace} ->
        keys = Keyword.get(replace, String.to_existing_atom(job.state), [])
        Repo.update(conf, Changeset.change(job, Map.take(changeset.changes, keys)), opts)

      :error ->
        {:ok, job}
    end
  rescue
    error in [Ecto.StaleEntryError] -> {:error, error}
  end

  # Helpers

  defp validate_config!(%Config{prefix: prefix}) when prefix != false do
    raise ArgumentError,
          "Oban.Engines.QuackDB doesn't support prefixes; configure Oban with prefix: false"
  end

  defp validate_config!(%Config{notifier: {notifier, _opts}} = conf)
       when notifier not in [Oban.Notifiers.PG, Oban.Notifiers.Isolated] do
    raise ArgumentError,
          "Oban.Engines.QuackDB requires Oban.Notifiers.PG or Oban.Notifiers.Isolated, " <>
            "got: #{inspect(conf.notifier)}"
  end

  defp validate_config!(%Config{peer: {Oban.Peers.Isolated, _opts}} = conf) do
    reject_reindexer!(conf)
  end

  defp validate_config!(%Config{peer: false} = conf) do
    reject_reindexer!(conf)
  end

  defp validate_config!(%Config{} = conf) do
    raise ArgumentError,
          "Oban.Engines.QuackDB only supports single-node operation with " <>
            "Oban.Peers.Isolated or peer: false, got: #{inspect(conf.peer)}"
  end

  defp reject_reindexer!(%Config{plugins: plugins}) do
    if Enum.any?(plugins, fn {plugin, _opts} -> plugin == Oban.Plugins.Reindexer end) do
      raise ArgumentError,
            "Oban.Engines.QuackDB doesn't support the PostgreSQL-specific Reindexer plugin"
    end

    :ok
  end

  defp update_ids(_conf, [], _opts), do: :ok

  defp update_ids(conf, jobs, opts) do
    ids = Enum.map(jobs, & &1.id)
    states = opts |> Keyword.fetch!(:where) |> Keyword.fetch!(:state)
    updates = Keyword.fetch!(opts, :set)

    Repo.update_all(
      conf,
      where(Job, [j], j.id in ^ids and j.state in ^states),
      set: updates
    )

    :ok
  end

  defp delete_ids(_conf, []), do: :ok

  defp delete_ids(conf, jobs) do
    ids = Enum.map(jobs, & &1.id)
    Repo.delete_all(conf, where(Job, [j], j.id in ^ids))
    :ok
  end

  defp seconds_from_now(seconds), do: DateTime.add(utc_now(), seconds, :second)
end
