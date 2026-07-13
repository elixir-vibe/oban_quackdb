defmodule Oban.QuackDB.MigrationsTest do
  use ExUnit.Case, async: false

  alias Oban.QuackDB.{TestMigration, TestRepo}

  test "migrates QuackDB storage up and down" do
    assert Oban.Migrations.QuackDB.current_version() == 1
    assert Oban.Migrations.QuackDB.migrated_version(repo: TestRepo) == 1
    assert table_exists?("oban_jobs")
    assert table_exists?("oban_locks")
    assert index_exists?("oban_jobs_fetch_index")
    assert %{rows: [["unique"]]} = TestRepo.query!("SELECT name FROM oban_locks")

    assert :ok = Ecto.Migrator.down(TestRepo, 1, TestMigration, log: false)
    refute table_exists?("oban_jobs")
    refute table_exists?("oban_locks")

    assert :ok = Ecto.Migrator.up(TestRepo, 1, TestMigration, log: false)
    assert table_exists?("oban_jobs")
    assert table_exists?("oban_locks")

    assert %{rows: [["JSON[]"]]} =
             TestRepo.query!("""
             SELECT data_type
             FROM information_schema.columns
             WHERE table_schema = current_schema()
             AND table_name = 'oban_jobs'
             AND column_name = 'errors'
             """)
  end

  defp table_exists?(table) do
    %{rows: [[count]]} =
      TestRepo.query!(
        """
        SELECT count(*)
        FROM information_schema.tables
        WHERE table_schema = current_schema() AND table_name = ?
        """,
        [table]
      )

    count == 1
  end

  defp index_exists?(index) do
    %{rows: [[count]]} =
      TestRepo.query!(
        """
        SELECT count(*)
        FROM duckdb_indexes()
        WHERE schema_name = current_schema() AND index_name = ?
        """,
        [index]
      )

    count == 1
  end
end
