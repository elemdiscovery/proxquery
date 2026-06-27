# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.1.0](https://github.com/elemdiscovery/proxquery/releases/tag/v0.1.0) - 2026-06-27

### Added

- *(bench)* add large-scale benchmark suite with CI workflow
- [**breaking**] rename ts_prox_chain, fix span semantics, add release pipeline ([#3](https://github.com/elemdiscovery/proxquery/pull/3))
- add pure-SQL port for use on managed Postgres (no extension required)
- support wildcards inside phrases and fail fast on malformed regex
- add proxquery, positional proximity search on tsvector

### Other

- word frequency information from https://www.wordfrequency.info. Top 5000 sample is only allowed for distribution with attribution.
- README update.
- *(deps)* bump Swatinem/rust-cache in the actions group
- pin GitHub Actions to SHAs and add Dependabot
- Initial commit
