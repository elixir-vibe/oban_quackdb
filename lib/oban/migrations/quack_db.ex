defmodule Oban.Migrations.QuackDB do
  @moduledoc """
  Creates and removes the DuckDB tables required by `Oban.Engines.QuackDB`.

  Call the migration from an Ecto migration running against a QuackDB repo:

      def up, do: Oban.Migrations.QuackDB.up()
      def down, do: Oban.Migrations.QuackDB.down()
  """

  @behaviour Oban.Migration

  use Ecto.Migration

  def current_version, do: 1

  @impl Oban.Migration
  def up(_opts \\ []) do
    execute("CREATE SEQUENCE IF NOT EXISTS oban_jobs_id_seq")

    # DuckDB doesn't support adding constraints after table creation. Use inline DDL to preserve
    # the same database-level checks as the core job schema.
    execute("""
    CREATE TABLE IF NOT EXISTS oban_jobs (
      id BIGINT DEFAULT nextval('oban_jobs_id_seq') PRIMARY KEY,
      state VARCHAR NOT NULL DEFAULT 'available',
      queue VARCHAR NOT NULL DEFAULT 'default',
      worker VARCHAR NOT NULL,
      args JSON NOT NULL DEFAULT '{}',
      meta JSON NOT NULL DEFAULT '{}',
      tags VARCHAR[] NOT NULL DEFAULT [],
      errors JSON[] NOT NULL DEFAULT [],
      attempt INTEGER NOT NULL DEFAULT 0,
      attempted_by VARCHAR[] NOT NULL DEFAULT [],
      max_attempts INTEGER NOT NULL DEFAULT 20,
      priority INTEGER NOT NULL DEFAULT 0,
      attempted_at TIMESTAMPTZ,
      cancelled_at TIMESTAMPTZ,
      completed_at TIMESTAMPTZ,
      discarded_at TIMESTAMPTZ,
      inserted_at TIMESTAMPTZ NOT NULL DEFAULT now(),
      scheduled_at TIMESTAMPTZ NOT NULL DEFAULT now(),
      CONSTRAINT attempt_range CHECK (attempt >= 0 AND attempt <= max_attempts),
      CONSTRAINT positive_max_attempts CHECK (max_attempts > 0),
      CONSTRAINT priority_range CHECK (priority >= 0 AND priority <= 9),
      CONSTRAINT queue_length CHECK (length(queue) > 0 AND length(queue) <= 128),
      CONSTRAINT worker_length CHECK (length(worker) > 0 AND length(worker) <= 128)
    )
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS oban_jobs_fetch_index
    ON oban_jobs (state, queue, priority, scheduled_at, id)
    """)

    execute("""
    CREATE TABLE IF NOT EXISTS oban_locks (
      name VARCHAR PRIMARY KEY,
      revision BIGINT NOT NULL DEFAULT 0
    )
    """)

    execute("INSERT INTO oban_locks (name) VALUES ('unique') ON CONFLICT DO NOTHING")

    :ok
  end

  @impl Oban.Migration
  def down(_opts \\ []) do
    execute("DROP TABLE IF EXISTS oban_locks")
    execute("DROP TABLE IF EXISTS oban_jobs")
    execute("DROP SEQUENCE IF EXISTS oban_jobs_id_seq")

    :ok
  end

  @impl Oban.Migration
  def migrated_version(opts \\ []) do
    repo = Keyword.get_lazy(opts, :repo, fn -> repo() end)

    query = """
    SELECT count(*)
    FROM information_schema.tables
    WHERE table_schema = current_schema() AND table_name = 'oban_jobs'
    """

    case repo.query(query, [], log: false) do
      {:ok, %{rows: [[1]]}} -> 1
      _ -> 0
    end
  end
end
