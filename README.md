# Oban QuackDB

An experimental [QuackDB](https://github.com/elixir-vibe/quackdb) engine for
[Oban](https://github.com/oban-bg/oban).

Oban QuackDB provides:

- `Oban.Engines.QuackDB` for durable job orchestration on DuckDB;
- `Oban.Migrations.QuackDB` for DuckDB-native storage; and
- transaction-conflict retries for concurrent claiming and unique insertion.

QuackDB and DuckDB's Quack protocol are experimental. This integration currently targets
single-node deployments and should be validated against your workload before it is used for
critical jobs.

## Installation

Add `oban_quackdb` to your dependencies:

```elixir
def deps do
  [
    {:oban_quackdb, "~> 0.1.0"}
  ]
end
```

The package requires Elixir 1.19+, Oban 2.23.x, QuackDB 0.5.17+, and DuckDB 1.5.3+.

## Repo

Define an Ecto repo backed by QuackDB:

```elixir
defmodule MyApp.ObanRepo do
  use Ecto.Repo,
    otp_app: :my_app,
    adapter: Ecto.Adapters.QuackDB
end
```

Configure the repo with the Quack endpoint and token. Set the custom migrator so Oban can verify
its storage when custom migrator resolution is available:

```elixir
config :my_app, MyApp.ObanRepo,
  migrator: Oban.Migrations.QuackDB,
  uri: "http://[::1]:9494",
  token: System.fetch_env!("QUACKDB_TOKEN")
```

The application owns the DuckDB server lifecycle. For example, start a dedicated managed server
before the repo in your supervision tree:

```elixir
children = [
  {QuackDB.Server,
   name: MyApp.ObanDuckDB,
   database: System.fetch_env!("OBAN_DUCKDB_DATABASE"),
   endpoint: "quack:localhost:9495",
   token: System.fetch_env!("QUACKDB_TOKEN")},
  MyApp.ObanRepo,
  {Oban, Application.fetch_env!(:my_app, Oban)}
]
```

Use persistent storage for Oban jobs; don't use QuackDB's rebuildable `:no_wal_writes` recovery
mode. See QuackDB's [managed-server guide](https://hexdocs.pm/quackdb/managed-duckdb.html) for
lifecycle and deployment details.

## Migration

Generate an Ecto migration and call the package migration directly:

```elixir
defmodule MyApp.ObanRepo.Migrations.AddOban do
  use Ecto.Migration

  def up, do: Oban.Migrations.QuackDB.up()
  def down, do: Oban.Migrations.QuackDB.down()
end
```

## Oban configuration

Configure the external engine explicitly:

```elixir
config :my_app, Oban,
  engine: Oban.Engines.QuackDB,
  notifier: Oban.Notifiers.PG,
  peer: Oban.Peers.Isolated,
  prefix: false,
  queues: [default: 10],
  repo: MyApp.ObanRepo
```

Cron, Pruner, and Lifeline are supported for single-node use. The engine validates producer
configuration and raises for prefixes, database-backed peers, unsupported notifiers, or the
PostgreSQL-specific Reindexer plugin.

## Current limitations

- Single-node operation only.
- No prefix support.
- No Reindexer support.
- DuckDB and Quack transaction behavior remains experimental.
- Oban 2.23.0 can't resolve a configured external migrator outside an Ecto migration runner. The
  package can run in normal mode, but release-quality `testing: :manual` support requires the
  generic custom-migrator fallback in Oban to use the configured repo directly.

## License

Apache-2.0. The engine and migration are derived from Oban's Apache-2.0 implementation and adapted
for QuackDB and DuckDB semantics.
