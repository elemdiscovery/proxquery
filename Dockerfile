# A Postgres image with proxquery preinstalled.
# PG_MAJOR must be one of the versions the crate supports (16, 17, 18).
ARG PG_MAJOR=17

FROM rust:1-bookworm AS build
ARG PGRX_VERSION=0.19.1

COPY packaging/pgdg-ACCC4CF8.asc /usr/share/postgresql-common/pgdg/apt.postgresql.org.asc
RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
      ca-certificates gnupg lsb-release \
      build-essential bison flex libreadline-dev zlib1g-dev libssl-dev pkg-config; \
    echo "deb [signed-by=/usr/share/postgresql-common/pgdg/apt.postgresql.org.asc] http://apt.postgresql.org/pub/repos/apt $(lsb_release -cs)-pgdg main" \
      > /etc/apt/sources.list.d/pgdg.list

RUN cargo install --locked "cargo-pgrx@${PGRX_VERSION}"

ARG PG_MAJOR
RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends "postgresql-server-dev-${PG_MAJOR}"; \
    rm -rf /var/lib/apt/lists/*

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

# Preserve standalone binaries as `export` for direct packaging.
FROM scratch AS export
COPY --from=build /out/ /

# The actual postgres container.
FROM postgres:${PG_MAJOR}-bookworm
ARG PG_MAJOR
LABEL org.opencontainers.image.source="https://github.com/elemdiscovery/proxquery"
LABEL org.opencontainers.image.description="PostgreSQL ${PG_MAJOR} with the proxquery extension preinstalled"
LABEL org.opencontainers.image.licenses="MIT"
COPY --from=build /out/proxquery.so /usr/lib/postgresql/${PG_MAJOR}/lib/
COPY --from=build /out/proxquery.control /out/proxquery--*.sql \
     /usr/share/postgresql/${PG_MAJOR}/extension/
