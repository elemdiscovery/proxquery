#!/usr/bin/env bash
# Run the pure-SQL-vs-extension benchmark and write a timestamped Markdown
# report (timing + machine/version context) into bench/reports/ (gitignored).
#
# Connection uses standard libpq env vars (PGHOST, PGPORT, PGUSER, ...). The
# script creates and drops a scratch database, so the role needs CREATEDB.
# Examples:
#   bench/report.sh                                   # local default psql
#   PGHOST=$HOME/.pgrx PGPORT=28817 bench/report.sh   # a cargo-pgrx instance
#
# Tunables (env): NDOCS (20000), WLEN (40), ITERS (5), MAINT_DB (postgres).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NDOCS="${NDOCS:-20000}"; WLEN="${WLEN:-40}"; ITERS="${ITERS:-5}"
MAINT_DB="${MAINT_DB:-postgres}"
BENCH_DB="${BENCH_DB:-proxquery_bench_$$}"
OUT_DIR="$ROOT/bench/reports"; mkdir -p "$OUT_DIR"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
REPORT="$OUT_DIR/pure_vs_extension_${STAMP}.md"

psqlq() { psql -X -q -v ON_ERROR_STOP=1 "$@"; }
psqlv() { psql -X -tA "$@"; }

cleanup() { psql -X -q -d "$MAINT_DB" -c "DROP DATABASE IF EXISTS \"$BENCH_DB\"" >/dev/null 2>&1 || true; }
trap cleanup EXIT

psqlq -d "$MAINT_DB" -c "CREATE DATABASE \"$BENCH_DB\""

cd "$ROOT"   # so the bench's `\i sql/proxquery_pure.sql` resolves
start=$(date +%s)
raw="$(psqlq -d "$BENCH_DB" -v ndocs="$NDOCS" -v wlen="$WLEN" -v iters="$ITERS" -f bench/pure_vs_extension.sql)"
# Custom Unicode tokenizer vs stock `simple` on an overlap-heavy corpus — a smoke
# regression check that superimposition doesn't blow up matching cost.
raw_tok="$(psqlq -d "$BENCH_DB" -v ndocs="$NDOCS" -v wlen="$WLEN" -v iters="$ITERS" -f bench/tokenizer_vs_simple.sql)"
wall=$(( $(date +%s) - start ))

# ---- context ----
pg_version="$(psqlv -d "$BENCH_DB" -c 'show server_version')"
pg_full="$(psqlv -d "$BENCH_DB" -c 'select version()')"
ext_version="$(psqlv -d "$BENCH_DB" -c "select extversion from pg_extension where extname='proxquery'" || true)"
host_os="$(uname -srm)"
cpu="$(sysctl -n machdep.cpu.brand_string 2>/dev/null \
      || { command -v lscpu >/dev/null 2>&1 && lscpu | sed -n 's/^Model name: *//p'; } \
      || echo unknown)"
mem="$(sysctl -n hw.memsize 2>/dev/null | awk '{printf "%.0f GiB", $1/1073741824}' \
      || awk '/MemTotal/{printf "%.0f GiB", $2/1048576}' /proc/meminfo 2>/dev/null \
      || echo unknown)"
cores="$(sysctl -n hw.ncpu 2>/dev/null || nproc 2>/dev/null || echo '?')"
# load averages (1/5/15m) — high load relative to cores means the timings below
# were taken under contention and should not be compared against an idle run.
loadavg="$(sysctl -n vm.loadavg 2>/dev/null | tr -d '{}' | awk '{printf "%s / %s / %s", $1,$2,$3}' \
      || cut -d' ' -f1-3 /proc/loadavg 2>/dev/null \
      || echo unknown)"
git_sha="$(git -C "$ROOT" rev-parse --short HEAD 2>/dev/null || echo unknown)"
git_dirty=""; { git -C "$ROOT" diff --quiet 2>/dev/null && git -C "$ROOT" diff --cached --quiet 2>/dev/null; } || git_dirty=" (dirty)"

# ---- psql aligned table -> markdown table ----
to_md_table() {
  awk -F'|' '
    /^[[:space:]]*-+\+/ { next }            # psql column-separator rule
    /^\([0-9]+ row/      { next }            # row-count footer
    NF < 2               { next }
    {
      out="|"; for (i=1;i<=NF;i++){ c=$i; gsub(/^[[:space:]]+|[[:space:]]+$/,"",c); out=out" "c" |" }
      print out
      if (!sep){ s="|"; for (i=1;i<=NF;i++) s=s" --- |"; print s; sep=1 }
    }'
}

results_md="$(printf '%s\n' "$raw" | sed -n '/== pure-SQL port vs native extension/,/([0-9]* rows)/p' | grep '|' | to_md_table || true)"
corpus_block="$(printf '%s\n' "$raw" | sed -n '/== corpus shape ==/,/^$/p' | sed '1d;/^$/d' || true)"
plan_block="$(printf '%s\n' "$raw" | sed -n '/== plan:/,/([0-9]* rows)/p' | sed '1d' || true)"
tok_corpus_md="$(printf '%s\n' "$raw_tok" | sed -n '/== corpus shape (lexeme/,/^$/p' | grep '|' | to_md_table || true)"
tok_results_md="$(printf '%s\n' "$raw_tok" | sed -n '/== tokenizer vs simple/,/([0-9]* rows)/p' | grep '|' | to_md_table || true)"

# ---- write the report ----
{
  echo "# proxquery — pure-SQL port vs native extension"
  echo
  echo "Generated $(date -u '+%Y-%m-%d %H:%M:%SZ') · commit \`${git_sha}\`${git_dirty}"
  echo
  echo "## Context"
  echo
  echo "| key | value |"
  echo "| --- | --- |"
  echo "| host | ${host_os} |"
  echo "| cpu | ${cpu} (${cores} cores) |"
  echo "| memory | ${mem} |"
  echo "| load avg (1/5/15m) | ${loadavg} |"
  echo "| postgres | ${pg_version} |"
  echo "| proxquery extension | ${ext_version:-n/a} |"
  echo "| corpus | ${NDOCS} docs × ${WLEN} tokens |"
  echo "| iterations / query | ${ITERS} |"
  echo "| total wall time | ${wall}s |"
  echo
  echo "## Results"
  echo
  echo "Average server-side ms/query over ${ITERS} runs (after a warmup). Timings are"
  echo "load-sensitive — check the load average in Context before comparing runs."
  echo "\`disagree\` is a row-set parity check between the two implementations (must be 0)."
  echo
  printf '%s\n' "$results_md"
  echo
  echo "- \`ext_op_ms\` — extension single operator \`tsv @~@ q\`"
  echo "- \`ext_2cl_ms\` — extension, written as the two-clause form"
  echo "- \`pure_2cl_ms\` — pure-SQL port, the same two clauses"
  echo "- \`slowdown\` — \`pure_2cl_ms / ext_2cl_ms\`"
  echo
  echo "## Tokenizer vs simple (overlap overhead)"
  echo
  echo "Custom Unicode tokenizer (\`proxquery_to_tsvector\`, which superimposes accent /"
  echo "hyphen / email lexemes) vs \`to_tsvector('simple', …)\` on one overlap-heavy corpus."
  echo "term/AND rows have identical selectivity (clean per-op cost ratio); proximity rows"
  echo "match more on prox (superimposition packs forms onto one position). \`ratio\` ="
  echo "\`prox_ms / simple_ms\` — a smoke check that superimposition doesn't blow up matching."
  echo
  printf '%s\n' "$tok_corpus_md"
  echo
  printf '%s\n' "$tok_results_md"
  echo
  echo "<details><summary>Corpus</summary>"
  echo
  echo '```'
  printf '%s\n' "$corpus_block"
  echo '```'
  echo
  echo "</details>"
  echo
  echo "<details><summary>Plan — pure two-clause (GIN-index-served)</summary>"
  echo
  echo '```'
  printf '%s\n' "$plan_block"
  echo '```'
  echo
  echo "</details>"
} > "$REPORT"

echo "wrote ${REPORT#$ROOT/}  (${wall}s wall)"
