#!/bin/sh
# Install proxquery into a PostgreSQL instance by copying this tarball's files
# into that server's extension directories. Bundled into every release tarball.
#
# Usage:
#   ./install.sh                          # target the Postgres on PATH (pg_config)
#   PG_CONFIG=/path/to/pg_config ./install.sh
#
# You need write access to the server's lib/share dirs — re-run under sudo if the
# copies fail with a permission error. Then, in the target database:
#   CREATE EXTENSION proxquery;
set -eu

PG_CONFIG="${PG_CONFIG:-pg_config}"
if ! command -v "$PG_CONFIG" >/dev/null 2>&1; then
  echo "error: '$PG_CONFIG' not found on PATH." >&2
  echo "       Install the PostgreSQL server dev tools, or set PG_CONFIG=/path/to/pg_config." >&2
  exit 1
fi

PKGLIBDIR="$("$PG_CONFIG" --pkglibdir)"
EXTDIR="$("$PG_CONFIG" --sharedir)/extension"
SRC="$(cd "$(dirname "$0")" && pwd)"

echo "Target Postgres : $("$PG_CONFIG" --version)"
echo "  module dir    : $PKGLIBDIR"
echo "  extension dir : $EXTDIR"

# install(1) creates parents and sets sane modes; -v echoes each file.
install -d "$PKGLIBDIR" "$EXTDIR"
install -v -m 0755 "$SRC"/*.so "$PKGLIBDIR/"
install -v -m 0644 "$SRC"/proxquery.control "$SRC"/proxquery--*.sql "$EXTDIR/"

echo
echo "Done. In the target database, run:  CREATE EXTENSION proxquery;"
