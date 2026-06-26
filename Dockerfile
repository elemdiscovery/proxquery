# A Postgres image with proxquery preinstalled — the container/Kubernetes and
# "try it now" install path. Self-contained: builds the extension from source
# against the matching PGDG server-dev package so the .so is ABI- and
# glibc-compatible with the official postgres:<major>-bookworm runtime.
#
#   docker build --build-arg PG_MAJOR=17 -t proxquery:17 .
#   docker run --rm -e POSTGRES_PASSWORD=pw proxquery:17
#   # then:  CREATE EXTENSION proxquery;
#
# PG_MAJOR must be one of the versions the crate supports (16, 17, 18).
ARG PG_MAJOR=17

FROM rust:1-bookworm AS build
ARG PG_MAJOR
ARG PGRX_VERSION=0.19.1

# Add the PGDG apt repo and install the matching server headers. Building against
# the same packages the runtime image uses keeps the .so loadable there.
RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
      ca-certificates curl gnupg lsb-release \
      build-essential bison flex libreadline-dev zlib1g-dev libssl-dev pkg-config; \
    install -d /usr/share/postgresql-common/pgdg; \
    curl -fsSL https://www.postgresql.org/media/keys/ACCC4CF8.asc \
      -o /usr/share/postgresql-common/pgdg/apt.postgresql.org.asc; \
    echo "deb [signed-by=/usr/share/postgresql-common/pgdg/apt.postgresql.org.asc] http://apt.postgresql.org/pub/repos/apt $(lsb_release -cs)-pgdg main" \
      > /etc/apt/sources.list.d/pgdg.list; \
    apt-get update; \
    apt-get install -y --no-install-recommends "postgresql-server-dev-${PG_MAJOR}"; \
    rm -rf /var/lib/apt/lists/*

RUN cargo install --locked "cargo-pgrx@${PGRX_VERSION}"

WORKDIR /src
COPY . .

# Wire pgrx to the PGDG install (reuse its binaries, don't rebuild Postgres),
# package, then collect the three install artifacts into /out regardless of the
# tree layout pgrx produces.
RUN set -eux; \
    PGCONFIG="$(command -v "pg_config" || echo "/usr/lib/postgresql/${PG_MAJOR}/bin/pg_config")"; \
    cargo pgrx init "--pg${PG_MAJOR}" "$PGCONFIG"; \
    cargo pgrx package --no-default-features "--features" "pg${PG_MAJOR}" --pg-config "$PGCONFIG"; \
    mkdir -p /out; \
    find target -name 'proxquery.so'        -path '*release*' -exec cp {} /out/ \; ; \
    find target -name 'proxquery.control'   -path '*release*' -exec cp {} /out/ \; ; \
    find target -name 'proxquery--*.sql'    -path '*release*' -exec cp {} /out/ \;

FROM postgres:${PG_MAJOR}-bookworm
ARG PG_MAJOR
LABEL org.opencontainers.image.source="https://github.com/elemdiscovery/proxquery"
LABEL org.opencontainers.image.description="PostgreSQL ${PG_MAJOR} with the proxquery extension preinstalled"
LABEL org.opencontainers.image.licenses="MIT"
COPY --from=build /out/proxquery.so /usr/lib/postgresql/${PG_MAJOR}/lib/
COPY --from=build /out/proxquery.control /out/proxquery--*.sql \
     /usr/share/postgresql/${PG_MAJOR}/extension/
