# Changelog

## Unreleased

### Added

- Added the experimental `Oban.Engines.QuackDB` engine.
- Added DuckDB-native Oban migrations.
- Added bounded retries for classified QuackDB transaction conflicts.
- Added explicit validation for unsupported prefixes, peers, notifiers, and Reindexer configuration.
- Added support for disabling transaction retries in nested transaction contexts.
