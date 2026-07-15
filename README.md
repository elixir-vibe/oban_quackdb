# Oban QuackDB

[![Hex.pm](https://img.shields.io/hexpm/v/oban_quackdb.svg)](https://hex.pm/packages/oban_quackdb)
[![HexDocs](https://img.shields.io/badge/hex-docs-lightgreen.svg)](https://hexdocs.pm/oban_quackdb)
[![CI](https://github.com/elixir-vibe/oban_quackdb/actions/workflows/ci.yml/badge.svg)](https://github.com/elixir-vibe/oban_quackdb/actions/workflows/ci.yml)

Durable, single-node [Oban](https://github.com/oban-bg/oban) jobs in DuckDB, powered by
[QuackDB](https://github.com/elixir-vibe/quackdb).

Oban QuackDB provides a DuckDB-native engine and migrations while preserving Oban's job lifecycle,
uniqueness, claiming, retries, scheduled jobs, and maintenance plugins.

> [!WARNING]
> Oban QuackDB, QuackDB, and DuckDB's Quack protocol are experimental. This package is intended for
> single-node deployments and should be validated against your workload before it is used for
> critical jobs.

## Why Oban QuackDB?

Use Oban QuackDB when an application already owns a local DuckDB process and needs durable
background jobs without operating a separate PostgreSQL database.

It is designed to keep the behavior applications expect from Oban:

- transactional job claiming with optimistic retries under contention;
- serialized unique insertion through a dedicated DuckDB lock row;
- complete, snooze, retry, cancel, discard, rescue, prune, and bulk job operations;
- Cron, Pruner, and Lifeline support for a single Oban node; and
- native DuckDB storage for JSON arguments, metadata, tags, and error history.

It is not a multi-node Oban backend. Use a database with Oban's supported distributed peer and
notifier implementations when multiple application nodes must coordinate through shared storage.

## Compatibility

| Dependency | Supported version |
| --- | --- |
| Elixir | 1.19+ |
| Oban | 2.23.x |
| QuackDB | 0.5.17+ within the 0.5 series |
| DuckDB | 1.5.3+ |

The Oban dependency is intentionally limited to the 2.23 series because engines integrate with
Oban's internal execution contracts. Compatibility with each new Oban minor release is verified
before widening the requirement.

## Installation

Add `oban_quackdb` to your dependencies:

```elixir
def deps do
  [
    {:oban_quackdb, "~> 0.1.0"}
  ]
end
```

## Repo

Define a dedicated Ecto repo backed by QuackDB:

```elixir
defmodule MyApp.ObanRepo do
  use Ecto.Repo,
    otp_app: :my_app,
    adapter: Ecto.Adapters.QuackDB
end
```

Configure the repo in `runtime.exs` with the URI and token used by its DuckDB server:

```elixir
config :my_app, MyApp.ObanRepo,
  migrator: Oban.Migrations.QuackDB,
  uri: "http://[::1]:9495",
  token: System.fetch_env!("OBAN_QUACKDB_TOKEN")
```

## Supervision

The application owns the DuckDB server lifecycle. Start the server before the repo, and ensure
migrations run before Oban begins processing jobs:

```elixir
children = [
  {QuackDB.Server,
   name: MyApp.ObanDuckDB,
   duckdb: :managed,
   database: System.fetch_env!("OBAN_DUCKDB_DATABASE"),
   endpoint: "quack:localhost:9495",
   token: System.fetch_env!("OBAN_QUACKDB_TOKEN")},
  MyApp.ObanRepo,
  {Oban, Application.fetch_env!(:my_app, Oban)}
]
```

`OBAN_DUCKDB_DATABASE` must point to persistent storage. Don't enable QuackDB's rebuildable
`:no_wal_writes` recovery mode for job storage. See QuackDB's
[managed DuckDB guide](https://hexdocs.pm/quackdb/managed-duckdb.html) for binary installation,
server lifecycle, and deployment options.

## Migrations

Generate an Ecto migration for the dedicated repo:

```bash
mix ecto.gen.migration add_oban -r MyApp.ObanRepo
```

Call the package migration directly from the generated module:

```elixir
defmodule MyApp.ObanRepo.Migrations.AddOban do
  use Ecto.Migration

  def up, do: Oban.Migrations.QuackDB.up()
  def down, do: Oban.Migrations.QuackDB.down()
end
```

Run the migration before Oban starts:

```bash
mix ecto.migrate -r MyApp.ObanRepo
```

It creates `oban_jobs`, the job ID sequence, the fetch index, and the `oban_locks` row used to
serialize unique inserts.

## Oban configuration

Configure every QuackDB-specific option explicitly:

```elixir
config :my_app, Oban,
  engine: Oban.Engines.QuackDB,
  notifier: Oban.Notifiers.PG,
  peer: Oban.Peers.Isolated,
  prefix: false,
  queues: [default: 10],
  repo: MyApp.ObanRepo
```

These settings are intentional:

- `Oban.Notifiers.PG` provides local process-group notifications without PostgreSQL;
- the isolated peer makes the single node the leader; and
- `prefix: false` prevents Ecto from targeting a PostgreSQL-style schema.

The engine rejects unsupported prefixes, database-backed peers, notifiers, and the
PostgreSQL-specific Reindexer plugin when producers initialize.

## Plugins

| Plugin | Support |
| --- | --- |
| `Oban.Plugins.Cron` | Supported for a single node |
| `Oban.Plugins.Pruner` | Supported |
| `Oban.Plugins.Lifeline` | Supported |
| `Oban.Plugins.Reindexer` | Unsupported; PostgreSQL-specific |

Custom plugins are compatible when they use Oban's engine callbacks and don't issue
PostgreSQL-specific SQL.

## Operational notes

- Run one application node against an Oban DuckDB database.
- Keep the database and WAL on persistent storage and include them in backup planning.
- Let QuackDB supervise DuckDB shutdown so committed jobs are flushed cleanly.
- Use a dedicated repo and database rather than mixing jobs into rebuildable analytical storage.
- Treat transaction-conflict exhaustion as an operational signal; retries are bounded.

## Current limitations

- Single-node operation only.
- No schema prefix support.
- No database-backed peer or distributed notifier.
- No Reindexer support.
- DuckDB and Quack transaction behavior remains experimental.
- Oban 2.23.0 can't resolve a configured external migrator outside an Ecto migration runner.
  `testing: :manual` isn't supported until an Oban release includes the generic custom-migrator
  fix; normal runtime operation and direct `Oban.Migrations.QuackDB` migrations are supported.

## Part of Elixir Vibe

Oban QuackDB connects Oban's durable job model with QuackDB's supervised DuckDB stack. See the
[Elixir Vibe](https://github.com/elixir-vibe) organization for the surrounding tools and
libraries.

## License

[Apache-2.0](LICENSE.txt). The engine and migration are derived from Oban's Apache-2.0
implementation and retain its copyright and license terms.
