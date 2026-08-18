#!/usr/bin/env bash
# Run the large, repeatable proxquery benchmark and write a timestamped Markdown
# report into bench/reports/ (gitignored). Two tiers from one corpus generator:
#
#   * SMALL (default 100 MiB): native extension + pure-SQL port, head to head,
#     with a per-query parity gate (the real pass/fail of the job).
#   * LARGE (default 1024 MiB): native extension only — how it scales when the
#     pure port would be far too slow.
#
# Each tier can also build a RUM index alongside GIN and compare them head to head
# (RUN_RUM / RUN_RUM_LARGE). RUM is skipped with a NOTICE if it isn't installed.
# The large-tier RUM pass is OFF by default for two reasons: a RUM build over a
# multi-GiB corpus is slow, AND RUM (1.3.15) SEGFAULTS on short high-cardinality
# prefix (`:*`) queries at ~1 GiB scale — e.g. proxquery lowers `... <~2> ha*` to
# the skeleton `... & ha:*`, and RUM's prefix scan crashes on the huge posting list
# (a RUM bug; GIN and proxquery's recheck are unaffected, and it does NOT reproduce
# at <=200 MiB). Enable RUN_RUM_LARGE=1 only knowingly.
#
# Both corpora are generated deterministically from the same seeds, so a given
# set of parameters always reproduces the same corpus and the same query list.
#
# Connection uses standard libpq env vars (PGHOST, PGPORT, PGUSER, ...). The role
# needs CREATEDB (the script creates and drops scratch databases). Run anywhere;
# it cd's to the repo root so the SQL's repo-relative \copy paths resolve.
#
# Tunables (env, with defaults):
#   SEED 0.42  QSEED 0.137
#   SMALL_MB 100   SMALL_QUERIES 100   SMALL_ITERS 2
#   LARGE_MB 1024  LARGE_QUERIES 200   LARGE_ITERS 3
#   TAIL_WORDS 50000  ZIPF_S 1.3  MAINT_DB postgres
#   RUN_LARGE 1  (set 0 to skip the large extension-only tier)
#   RUN_RUM 1        (small tier: also build a RUM index and compare it to GIN)
#   RUN_RUM_LARGE 0  (large tier: include the RUM comparison — off by default)
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"

SEED="${SEED:-0.42}";            QSEED="${QSEED:-0.137}"
SMALL_MB="${SMALL_MB:-100}";     SMALL_QUERIES="${SMALL_QUERIES:-100}";  SMALL_ITERS="${SMALL_ITERS:-2}"
LARGE_MB="${LARGE_MB:-1024}";    LARGE_QUERIES="${LARGE_QUERIES:-200}";  LARGE_ITERS="${LARGE_ITERS:-3}"
TAIL_WORDS="${TAIL_WORDS:-50000}"; ZIPF_S="${ZIPF_S:-1.3}"
RUN_LARGE="${RUN_LARGE:-1}"
RUN_RUM="${RUN_RUM:-1}";          RUN_RUM_LARGE="${RUN_RUM_LARGE:-0}"
MAINT_DB="${MAINT_DB:-postgres}"

OUT_DIR="$ROOT/bench/reports"; mkdir -p "$OUT_DIR"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
REPORT="$OUT_DIR/large_bench_${STAMP}.md"

SQL="bench/large/large_bench.sql"
psqlq() { psql -X -q -v ON_ERROR_STOP=1 "$@"; }
psqlv() { psql -X -tA "$@"; }

# scratch databases, cleaned up on exit
DB_S="proxquery_lb_s_$$"; DB_L="proxquery_lb_l_$$"
cleanup() {
  for db in "$DB_S" "$DB_L"; do
    psql -X -q -d "$MAINT_DB" -c "DROP DATABASE IF EXISTS \"$db\"" >/dev/null 2>&1 || true
  done
}
trap cleanup EXIT

# psql aligned table -> Markdown table (same approach as bench/report.sh)
to_md_table() {
  awk -F'|' '
    /^[[:space:]]*-+\+/ { next }
    /^\([0-9]+ row/      { next }
    NF < 2               { next }
    { out="|"; for (i=1;i<=NF;i++){ c=$i; gsub(/^[[:space:]]+|[[:space:]]+$/,"",c); out=out" "c" |" }
      print out
      if (!sep){ s="|"; for (i=1;i<=NF;i++) s=s" --- |"; print s; sep=1 } }'
}
# extract the psql output between a "== header ==" line and the next blank line,
# then render it as a Markdown table
section() { printf '%s\n' "$1" | sed -n "/== $2 /,/^$/p" | grep '|' | to_md_table || true; }

# The index-disabled (seq scan) baseline (`with_seqscan`) is OFF here: a whole-corpus
# recheck per query would dominate these tiers. It's measured only by the small PR report
# (bench/report.sh), which pairs it with the index-vs-seq-scan correctness test.
echo "[large-bench] SMALL tier: ${SMALL_MB} MiB, ${SMALL_QUERIES} queries (extension + pure)" >&2
psqlq -d "$MAINT_DB" -c "CREATE DATABASE \"$DB_S\""
s_start=$(date +%s)
raw_small="$(psqlq -d "$DB_S" \
  -v seed="$SEED" -v qseed="$QSEED" -v target_mb="$SMALL_MB" \
  -v tail_words="$TAIL_WORDS" -v zipf_s="$ZIPF_S" \
  -v nqueries="$SMALL_QUERIES" -v iters="$SMALL_ITERS" -v with_pure=1 -v with_rum="$RUN_RUM" -v with_seqscan=0 -f "$SQL")"
s_wall=$(( $(date +%s) - s_start ))
# raw per-query timings, for an easy reference point (gitignored). `am` distinguishes
# the GIN vs RUM operator rows; ext_search/pure are only populated on the GIN rows.
psqlq -d "$DB_S" -c "\copy (SELECT am, id, shape, q, candidates, matches, ext_op_ms, ext_search_ms, pure_search_ms FROM results ORDER BY am, id) TO 'bench/reports/results_small.csv' WITH (FORMAT csv, HEADER true)"

raw_large=""; l_wall=0
if [ "$RUN_LARGE" = "1" ]; then
  echo "[large-bench] LARGE tier: ${LARGE_MB} MiB, ${LARGE_QUERIES} queries (extension only)" >&2
  psqlq -d "$MAINT_DB" -c "CREATE DATABASE \"$DB_L\""
  l_start=$(date +%s)
  raw_large="$(psqlq -d "$DB_L" \
    -v seed="$SEED" -v qseed="$QSEED" -v target_mb="$LARGE_MB" \
    -v tail_words="$TAIL_WORDS" -v zipf_s="$ZIPF_S" \
    -v nqueries="$LARGE_QUERIES" -v iters="$LARGE_ITERS" -v with_pure=0 -v with_rum="$RUN_RUM_LARGE" -v with_seqscan=0 -f "$SQL")"
  l_wall=$(( $(date +%s) - l_start ))
  psqlq -d "$DB_L" -c "\copy (SELECT am, id, shape, q, candidates, matches, ext_op_ms FROM results ORDER BY am, id) TO 'bench/reports/results_large.csv' WITH (FORMAT csv, HEADER true)"
fi

# ---- machine / version context ----
pg_version="$(psqlv -d "$DB_S" -c 'show server_version')"
ext_version="$(psqlv -d "$DB_S" -c "select extversion from pg_extension where extname='proxquery'" || true)"
host_os="$(uname -srm)"
cpu="$(sysctl -n machdep.cpu.brand_string 2>/dev/null \
      || { command -v lscpu >/dev/null 2>&1 && lscpu | sed -n 's/^Model name: *//p'; } || echo unknown)"
mem="$(sysctl -n hw.memsize 2>/dev/null | awk '{printf "%.0f GiB", $1/1073741824}' \
      || awk '/MemTotal/{printf "%.0f GiB", $2/1048576}' /proc/meminfo 2>/dev/null || echo unknown)"
cores="$(sysctl -n hw.ncpu 2>/dev/null || nproc 2>/dev/null || echo '?')"
git_sha="$(git -C "$ROOT" rev-parse --short HEAD 2>/dev/null || echo unknown)"
git_dirty=""; { git -C "$ROOT" diff --quiet 2>/dev/null && git -C "$ROOT" diff --cached --quiet 2>/dev/null; } || git_dirty=" (dirty)"

# ---- write the report ----
{
  echo "# proxquery — large performance benchmark"
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
  echo "| postgres | ${pg_version} |"
  echo "| proxquery extension | ${ext_version:-n/a} |"
  echo "| seed / qseed | ${SEED} / ${QSEED} |"
  echo "| small tier | ${SMALL_MB} MiB, ${SMALL_QUERIES} queries, ${SMALL_ITERS} iters$( [ "$RUN_RUM" = "1" ] && echo ", GIN+RUM") — ${s_wall}s |"
  [ "$RUN_LARGE" = "1" ] && echo "| large tier | ${LARGE_MB} MiB, ${LARGE_QUERIES} queries, ${LARGE_ITERS} iters$( [ "$RUN_RUM_LARGE" = "1" ] && echo ", GIN+RUM") — ${l_wall}s |"
  echo
  echo "Timings are average server-side ms/query and are load-sensitive — on a"
  echo "shared CI runner read them as a smoke + parity check, not a perf baseline."
  echo
  echo "## Small tier — extension vs pure-SQL port (${SMALL_MB} MiB)"
  echo
  echo "Phase timing (wall seconds — where the run's time went)"
  echo
  section "$raw_small" "phase timing"
  echo
  echo "Vocabulary"
  echo
  section "$raw_small" "vocabulary"
  echo
  echo "Corpus"
  echo
  section "$raw_small" "corpus shape"
  echo
  echo "Index size (by am)"
  echo
  section "$raw_small" "index size"
  echo
  echo "Overall (avg ms/query; \`slowdown\` = pure_search / ext_search)"
  echo
  section "$raw_small" "results: overall"
  echo
  echo "By query shape"
  echo
  section "$raw_small" "results: by query shape"
  echo
  # The RUM comparison renders only when the RUM pass actually ran; the parity
  # section is emitted only then, so its presence is the signal.
  rum_parity_small="$(section "$raw_small" "index parity")"
  if [ -n "$rum_parity_small" ]; then
    echo "### GIN vs RUM index comparison"
    echo
    echo "Overall (\`@~@\` operator, avg ms/query per index am)"
    echo
    section "$raw_small" "index comparison overall"
    echo
    echo "By query shape — \`rum_vs_gin\` < 1 means RUM is faster. RUM prunes lexeme"
    echo "positions in-index, so it wins on the native shapes the simplify path lowers"
    echo "to a real phrase/exact tsquery (\`phrase\`, \`ordered\`); on the lossy proximity"
    echo "shapes both AMs select the same \`a & b\` candidates, so RUM only costs storage."
    echo
    section "$raw_small" "index comparison by shape"
    echo
    echo "Index parity (RUM vs GIN \`@~@\` match counts; \`mismatches\` must be 0)"
    echo
    printf '%s\n' "$rum_parity_small"
    echo
  fi
  echo "<details><summary>Per-query breakdown — all ${SMALL_QUERIES} queries (counts + timings)</summary>"
  echo
  section "$raw_small" "results: per query"
  echo
  echo "</details>"
  echo
  echo "Parity (extension vs pure match counts; mismatches must be 0)"
  echo
  section "$raw_small" "parity"
  if [ "$RUN_LARGE" = "1" ]; then
    echo
    echo "## Large tier — extension only (${LARGE_MB} MiB)"
    echo
    echo "Phase timing (wall seconds)"
    echo
    section "$raw_large" "phase timing"
    echo
    echo "Corpus"
    echo
    section "$raw_large" "corpus shape"
    echo
    echo "Index size (by am)"
    echo
    section "$raw_large" "index size"
    echo
    echo "Overall (avg ms/query)"
    echo
    section "$raw_large" "results: overall"
    echo
    echo "By query shape"
    echo
    section "$raw_large" "results: by query shape"
    echo
    rum_parity_large="$(section "$raw_large" "index parity")"
    if [ -n "$rum_parity_large" ]; then
      echo "### GIN vs RUM index comparison"
      echo
      echo "Overall (\`@~@\` operator, avg ms/query per index am)"
      echo
      section "$raw_large" "index comparison overall"
      echo
      echo "By query shape (\`rum_vs_gin\` < 1 = RUM faster)"
      echo
      section "$raw_large" "index comparison by shape"
      echo
      echo "Index parity (RUM vs GIN \`@~@\` match counts; \`mismatches\` must be 0)"
      echo
      printf '%s\n' "$rum_parity_large"
      echo
    fi
    echo "<details><summary>Per-query breakdown — all ${LARGE_QUERIES} queries (counts)</summary>"
    echo
    section "$raw_large" "results: per query"
    echo
    echo "</details>"
  fi
  echo
  echo "- \`ext_op_ms\` — extension single operator \`tsv @~@ q\` (real-world usage)"
  echo "- \`ext_search_ms\` — extension via the consolidated \`ts_prox_search(tsv, q)\` (small tier only)"
  echo "- \`pure_search_ms\` — pure-SQL port via the same \`ts_prox_search\` (small tier only)"
  echo "- \`index size (by am)\` — on-disk index size + build ms per AM; \`size_vs_gin\` = RUM size / GIN size"
  echo "- \`gin_op_ms\` / \`rum_op_ms\` — \`@~@\` avg ms/query on each index; \`rum_vs_gin\` = rum_op_ms / gin_op_ms"
  echo
  echo "Raw per-query timings: \`bench/reports/results_small.csv\`$( [ "$RUN_LARGE" = "1" ] && echo ", \`bench/reports/results_large.csv\`")."
} > "$REPORT"

echo "wrote ${REPORT#$ROOT/}  (small ${s_wall}s$( [ "$RUN_LARGE" = "1" ] && echo ", large ${l_wall}s"))" >&2
echo "$REPORT"
