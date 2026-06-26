#!/bin/sh
# Boot a proxquery Docker image and verify the extension actually loads.
# Used by .github/workflows/docker-smoke.yml (PR/main) and promote.yml (pre-push
# gate). Fails non-zero on any compile/ABI/load break.
#
# Usage: packaging/smoke.sh <image>
set -eu

IMAGE="${1:?usage: smoke.sh <image>}"
CONTAINER="proxquery-smoke-$$"

cleanup() { docker rm -f "$CONTAINER" >/dev/null 2>&1 || true; }
trap cleanup EXIT

docker run -d --name "$CONTAINER" -e POSTGRES_PASSWORD=smoke "$IMAGE" >/dev/null

# Wait for the server to accept connections.
ready=
i=0
while [ "$i" -lt 30 ]; do
  if docker exec "$CONTAINER" pg_isready -U postgres >/dev/null 2>&1; then ready=1; break; fi
  i=$((i + 1))
  sleep 2
done
if [ -z "$ready" ]; then
  echo "postgres never became ready" >&2
  docker logs "$CONTAINER" >&2
  exit 1
fi

run() { docker exec "$CONTAINER" psql -v ON_ERROR_STOP=1 -U postgres -c "$1"; }
# Loads the .so + installs the SQL — fails here on any compile/ABI break.
run "CREATE EXTENSION proxquery;"
# Exercise a scalar function and the indexable operator's support path.
run "SELECT ts_prox_within(to_tsvector('simple','the quick brown fox'), 'quick', 'fox', 2);"
run "SELECT to_tsvector('simple','the quick brown fox') @~@ 'quick <~3> fox';"

echo "smoke OK: $IMAGE"
