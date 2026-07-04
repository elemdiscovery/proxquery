#!/usr/bin/env bash
# Build and install the RUM index extension (github.com/postgrespro/rum) against a
# given PostgreSQL install, for the GIN-vs-RUM benchmark comparison. RUM is NOT in
# core PostgreSQL, so the benchmarks (bench/report.sh, bench/large/run.sh) skip the
# RUM pass unless it is installed; run this first to enable it.
#
# Usage:
#   bench/install_rum.sh [PG_CONFIG]
#   PG_CONFIG=/path/to/pg_config bench/install_rum.sh
#
# With a cargo-pgrx managed instance, point it at that instance's pg_config:
#   bench/install_rum.sh "$(sed -n 's/^pg17 = "\(.*\)"/\1/p' ~/.pgrx/config.toml)"
#
# Env:
#   RUM_REF   git tag/branch to build (default 1.3.15 — supports PostgreSQL 12+).
#   PG_CONFIG pg_config to build against (arg 1 wins; else this; else PATH).
#
# Building needs a C toolchain (make, a C compiler) and the PostgreSQL server
# headers that pg_config points at (a pgrx-built instance already has them).
set -euo pipefail

RUM_REF="${RUM_REF:-1.3.15}"
PG_CONFIG="${1:-${PG_CONFIG:-pg_config}}"

command -v "$PG_CONFIG" >/dev/null 2>&1 || { echo "error: pg_config not found: $PG_CONFIG" >&2; exit 1; }
command -v git  >/dev/null 2>&1 || { echo "error: git is required"  >&2; exit 1; }
command -v make >/dev/null 2>&1 || { echo "error: make is required" >&2; exit 1; }

echo "[install-rum] building RUM ${RUM_REF} against $("$PG_CONFIG" --version) ($PG_CONFIG)" >&2

workdir="$(mktemp -d)"
trap 'rm -rf "$workdir"' EXIT

git clone --depth 1 --branch "$RUM_REF" https://github.com/postgrespro/rum "$workdir/rum"
make -C "$workdir/rum" USE_PGXS=1 PG_CONFIG="$PG_CONFIG"
make -C "$workdir/rum" USE_PGXS=1 PG_CONFIG="$PG_CONFIG" install

echo "[install-rum] installed. Enable it in a database with: CREATE EXTENSION rum;" >&2
