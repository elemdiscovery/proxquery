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
# Tunables (env):
#   main by-shape table (large-bench small tier): SMALL_MB (32), NQUERIES (120),
#     LB_ITERS (2), SEED (0.42), QSEED (0.137)
#   supplementary sections: NDOCS (20000), WLEN (40), ITERS (5), SDOCS (2000)
#   MAINT_DB (postgres)
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# Main results table: the frequency-skewed large-bench query generator at a small
# corpus (varied terms across all 14 shapes + a real selectivity spread).
SMALL_MB="${SMALL_MB:-32}"; NQUERIES="${NQUERIES:-120}"; LB_ITERS="${LB_ITERS:-2}"
SEED="${SEED:-0.42}"; QSEED="${QSEED:-0.137}"
# Supplementary sections (tokenizer overhead, length scaling) keep their own corpora.
NDOCS="${NDOCS:-20000}"; WLEN="${WLEN:-40}"; ITERS="${ITERS:-5}"; SDOCS="${SDOCS:-2000}"
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

cd "$ROOT"   # so the bench's repo-relative `\i` / `\copy` paths resolve
start=$(date +%s)
# Main table: the large-bench small tier (deterministic COCA-frequency corpus +
# generated query mix), parity-gated. Far more term/selectivity variation than a
# fixed query list — the same generator behind the manual large benchmark, just
# small. RUN_LARGE is irrelevant here; we invoke large_bench.sql directly.
raw="$(psqlq -d "$BENCH_DB" -v seed="$SEED" -v qseed="$QSEED" \
        -v target_mb="$SMALL_MB" -v nqueries="$NQUERIES" -v iters="$LB_ITERS" \
        -v with_pure=1 -f bench/large/large_bench.sql)"
# Custom Unicode tokenizer vs stock `simple` on an overlap-heavy corpus — a smoke
# regression check that superimposition doesn't blow up matching cost.
raw_tok="$(psqlq -d "$BENCH_DB" -v ndocs="$NDOCS" -v wlen="$WLEN" -v iters="$ITERS" -f bench/tokenizer_vs_simple.sql)"
# Pure port vs extension as document length grows — demonstrates the pure port's
# O(L)-per-recheck position lookup scaling at a worse rate than the binary's O(log L).
raw_scale="$(psqlq -d "$BENCH_DB" -v sdocs="$SDOCS" -v iters="$ITERS" -f bench/scaling_by_length.sql)"
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

# Main results: the large-bench by-shape table + its parity / corpus / vocabulary
# sections and the two pushdown-plan guards.
results_md="$(printf '%s\n' "$raw" | sed -n '/== results: by query shape ==/,/([0-9]* row/p' | grep '|' | to_md_table || true)"
perquery_md="$(printf '%s\n' "$raw" | sed -n '/== results: per query/,/([0-9]* row/p' | grep '|' | to_md_table || true)"
parity_md="$(printf '%s\n' "$raw" | sed -n '/== parity (pure port vs extension/,/([0-9]* row/p' | grep '|' | to_md_table || true)"
vocab_md="$(printf '%s\n' "$raw" | sed -n '/== vocabulary ==/,/([0-9]* row/p' | grep '|' | to_md_table || true)"
corpus_block="$(printf '%s\n' "$raw" | sed -n '/== corpus shape ==/,/([0-9]* row/p' | grep '|' | to_md_table || true)"
plan_op_block="$(printf '%s\n' "$raw" | sed -n '/== plan: @~@ within/,/([0-9]* row/p' | sed '1d' || true)"
plan_search_block="$(printf '%s\n' "$raw" | sed -n '/== plan: ts_prox_search on a boolean/,/([0-9]* row/p' | sed '1d' || true)"
tok_corpus_md="$(printf '%s\n' "$raw_tok" | sed -n '/== corpus shape (lexeme/,/^$/p' | grep '|' | to_md_table || true)"
tok_results_md="$(printf '%s\n' "$raw_tok" | sed -n '/== tokenizer vs simple/,/([0-9]* row/p' | grep '|' | to_md_table || true)"
scale_results_md="$(printf '%s\n' "$raw_scale" | sed -n '/== scaling: pure vs extension recheck by text length/,/([0-9]* row/p' | grep '|' | to_md_table || true)"
scale_growth_md="$(printf '%s\n' "$raw_scale" | sed -n '/== scaling: growth vs shortest length/,/([0-9]* row/p' | grep '|' | to_md_table || true)"

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
  echo "| main corpus | ${SMALL_MB} MiB · ${NQUERIES} generated queries · ${LB_ITERS} iters |"
  echo "| tokenizer corpus | ${NDOCS} docs × ${WLEN} tokens · ${ITERS} iters |"
  echo "| scaling sweep | ${SDOCS} docs × {32,128,512,2048} tokens · ${ITERS} iters |"
  echo "| total wall time | ${wall}s |"
  echo
  echo "## Results — by query shape"
  echo
  echo "Average server-side ms/query over ${LB_ITERS} runs (after a warmup), over a"
  echo "deterministic COCA-frequency corpus and a generated query mix — so each shape is"
  echo "exercised across a real spread of term frequencies and selectivities (\`avg_cand\`"
  echo "= rows the \`@@\` skeleton selects, \`avg_match\` = rows that actually match)."
  echo "Timings are load-sensitive — check the load average in Context before comparing runs."
  echo
  printf '%s\n' "$results_md"
  echo
  echo "- \`ext_op_ms\` — extension single operator \`tsv @~@ q\`"
  echo "- \`ext_search_ms\` — extension via the consolidated \`ts_prox_search(tsv, q)\`"
  echo "- \`pure_search_ms\` — pure-SQL port via the same \`ts_prox_search\`"
  echo "- \`slowdown\` — \`pure_search_ms / ext_search_ms\`"
  echo
  echo "<details><summary>Per-query breakdown — all ${NQUERIES} queries (counts + timings)</summary>"
  echo
  printf '%s\n' "$perquery_md"
  echo
  echo "</details>"
  echo
  echo "Parity (extension vs pure match counts on the same corpus — \`mismatches\` must be 0;"
  echo "it is also gated independently, so a nonzero count fails this job):"
  echo
  printf '%s\n' "$parity_md"
  echo
  echo "## Tokenizer vs simple (overlap overhead)"
  echo
  echo "Custom Unicode tokenizer (\`proxquery_to_tsvector\`, which superimposes accent /"
  echo "hyphen / email lexemes) vs \`to_tsvector('simple', …)\` on one overlap-heavy corpus."
  echo "term/AND rows have identical selectivity (clean per-op cost ratio); proximity rows"
  echo "match more on prox (superimposition packs forms onto one position). \`ratio\` ="
  echo "\`prox_ms / simple_ms\`."
  echo
  printf '%s\n' "$tok_corpus_md"
  echo
  printf '%s\n' "$tok_results_md"
  echo
  echo "## Scaling by text length"
  echo
  echo "One chained query (\`a <~3> b <~3> c\`) rechecked over every doc, swept over four"
  echo "document lengths (32–2048 tokens). The query is chained so it stays non-native and"
  echo "both ports run their positional recheck. Each length's tsvectors are loaded into memory"
  echo "once with the TOAST detoast excluded, so the timed loop is just the recheck: the pure"
  echo "port reads positions with \`unnest(tsvector)\`, the extension binary-searches the sorted"
  echo "lexemes. \`slowdown\` = \`pure_ms / ext_ms\`; \`disagree\` is the per-length recheck parity"
  echo "check over all docs (must be 0)."
  echo
  printf '%s\n' "$scale_results_md"
  echo
  echo "Each column normalized to its shortest-length value, so the per-column growth rate is"
  echo "explicit."
  echo
  printf '%s\n' "$scale_growth_md"
  echo
  echo "<details><summary>Corpus &amp; vocabulary</summary>"
  echo
  printf '%s\n' "$vocab_md"
  echo
  printf '%s\n' "$corpus_block"
  echo
  echo "</details>"
  echo
  echo "<details><summary>Plan — @~@ operator on a within shape (index-served via the a&amp;b skeleton, not a seq scan)</summary>"
  echo
  echo '```'
  printf '%s\n' "$plan_op_block"
  echo '```'
  echo
  echo "</details>"
  echo
  echo "<details><summary>Plan — ts_prox_search on a boolean query (recheck folded away, Bitmap Index Scan)</summary>"
  echo
  echo '```'
  printf '%s\n' "$plan_search_block"
  echo '```'
  echo
  echo "</details>"
} > "$REPORT"

echo "wrote ${REPORT#$ROOT/}  (${wall}s wall)"
