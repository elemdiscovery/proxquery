#!/usr/bin/env bash
# Inspect the benchmark's generated queries locally — the deterministic query
# list, reproducibility fingerprints, and (by default) how many candidates and
# matches each query finds on a small corpus. Uses the SAME generation includes
# as the benchmark, so what you see is exactly what large_bench.sql runs.
#
# Writes bench/reports/inspect_queries.csv (id,shape,q) and, with a corpus,
# bench/reports/inspect_results.csv (id,shape,q,candidates,matches).
#
# Connection uses standard libpq env vars (PGHOST, PGPORT, PGUSER, ...); the role
# needs CREATEDB and the proxquery extension must be installed in the cluster.
#
# Tunables (env, with defaults):
#   NQUERIES 200   INSPECT_MB 50   INSPECT_CORPUS 1 (0 = list queries only, no corpus)
#   SEED 0.42   QSEED 0.137   TAIL_WORDS 50000   ZIPF_S 1.3   MAINT_DB postgres
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"

NQUERIES="${NQUERIES:-200}"; INSPECT_MB="${INSPECT_MB:-50}"; INSPECT_CORPUS="${INSPECT_CORPUS:-1}"
SEED="${SEED:-0.42}"; QSEED="${QSEED:-0.137}"
TAIL_WORDS="${TAIL_WORDS:-50000}"; ZIPF_S="${ZIPF_S:-1.3}"
MAINT_DB="${MAINT_DB:-postgres}"

mkdir -p bench/reports
DB="proxquery_inspect_$$"
cleanup() { psql -X -q -d "$MAINT_DB" -c "DROP DATABASE IF EXISTS \"$DB\"" >/dev/null 2>&1 || true; }
trap cleanup EXIT

# Override the proximity-distance range only when asked; otherwise the default
# lives solely in _queries.sql.
EXTRA=()
[ -n "${DIST_MIN:-}" ] && EXTRA+=(-v "dist_min=$DIST_MIN")
[ -n "${DIST_MAX:-}" ] && EXTRA+=(-v "dist_max=$DIST_MAX")

psql -X -q -v ON_ERROR_STOP=1 -d "$MAINT_DB" -c "CREATE DATABASE \"$DB\""
psql -X -q -v ON_ERROR_STOP=1 -d "$DB" \
  -v seed="$SEED" -v qseed="$QSEED" -v nqueries="$NQUERIES" \
  -v inspect_corpus="$INSPECT_CORPUS" -v target_mb="$INSPECT_MB" \
  -v tail_words="$TAIL_WORDS" -v zipf_s="$ZIPF_S" ${EXTRA[@]+"${EXTRA[@]}"} \
  -f bench/large/inspect.sql

echo
echo "queries  -> bench/reports/inspect_queries.csv"
[ "$INSPECT_CORPUS" = "1" ] && echo "results  -> bench/reports/inspect_results.csv"
