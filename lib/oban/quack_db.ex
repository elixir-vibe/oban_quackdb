defmodule Oban.QuackDB do
  @moduledoc """
  Experimental DuckDB support for Oban through the QuackDB Ecto adapter.

  The integration provides `Oban.Engines.QuackDB` for job orchestration and
  `Oban.Migrations.QuackDB` for durable job storage.

  QuackDB and DuckDB's Quack protocol are experimental. The initial integration is intentionally
  limited to single-node operation without prefixes or the PostgreSQL-specific Reindexer plugin.
  """
end
