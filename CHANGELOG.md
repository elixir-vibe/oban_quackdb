# Changelog

## 0.1.0 - 2026-07-15

Initial experimental release of DuckDB-backed Oban support through QuackDB.

### Added

- Added `Oban.Engines.QuackDB` with job insertion, claiming, scheduling, lifecycle, bulk operation,
  pruning, rescue, and update support.
- Added `Oban.Migrations.QuackDB` with DuckDB-native job storage, a fetch index, and serialized
  uniqueness locking.
- Added exact and keyed uniqueness checks for job arguments and metadata.
- Added bounded retries for classified QuackDB transaction conflicts, with support for disabling
  retries inside nested transaction contexts.
- Added single-node support for Oban's Cron, Pruner, and Lifeline plugins.
- Added explicit validation for unsupported prefixes, peers, notifiers, and Reindexer
  configuration.

### Compatibility

- Requires Elixir 1.19+, Oban 2.23.x, QuackDB 0.5.17+, and DuckDB 1.5.3+.
- Supports single-node operation with an isolated peer and local process-group notifications.
- Does not support prefixes, distributed peers, or the PostgreSQL-specific Reindexer plugin.
- Oban 2.23.0 doesn't support `testing: :manual` with an external migrator outside an Ecto
  migration runner; normal runtime operation and direct package migrations are supported.
