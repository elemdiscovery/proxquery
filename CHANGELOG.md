# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.4.0](https://github.com/elemdiscovery/proxquery/compare/v0.3.0...v0.4.0) - 2026-06-29

### Added

- Extended `ts_prox_query_exact` to support a config parameter.

## [0.3.0](https://github.com/elemdiscovery/proxquery/compare/v0.2.0...v0.3.0) - 2026-06-28

### Added

- [**breaking**] Consolidated `ts_prox_search` for pure SQL simplified usage. ([#17](https://github.com/elemdiscovery/proxquery/pull/17))

## [0.2.0](https://github.com/elemdiscovery/proxquery/compare/v0.1.0...v0.2.0) - 2026-06-28

### Added

- Small-ish proximity queries that can convert into an enumerated position search no longer need a recheck.
- Adding signed releases.
- Add extension only `proxquery_to_tsvector` with specialized tsvector positioning.
- fold glob literal runs through cfg for config-aware wildcard matching
- add config-aware overloads resolving query terms through a regconfig

### Fixed

- more release-plz fixes.
- release-plz config fix

## [0.1.0](https://github.com/elemdiscovery/proxquery/releases/tag/v0.1.0) - 2026-06-27

### Added

- large-scale benchmark suite with CI workflow
- pure-SQL port for use on managed Postgres (no extension required)
- support wildcards inside phrases and fail fast on malformed regex
- proxquery, positional proximity search on tsvector
