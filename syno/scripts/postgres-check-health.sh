#!/usr/bin/env bash
# postgres-check-health.sh
# Health check for the bundled PostgreSQL instance.
# Exit 0  → PostgreSQL is accepting connections.
# Exit 1  → PostgreSQL is not ready (not started, initialising, or crashed).
#
# Usage:
#   ./postgres-check-health.sh [--quiet]
#   Returns exit code; prints status to stdout unless --quiet is passed.
set -euo pipefail

PG_BIN="/var/packages/immich/target/postgres/bin"
PG_DATA="${SYNOPKG_PKGVAR:-/var/packages/immich/var}/pgdata"
DB_HOST="127.0.0.1"
DB_PORT="${DB_PORT:-5432}"

QUIET=false
if [[ "${1:-}" == "--quiet" ]]; then
    QUIET=true
fi

_say() {
    ${QUIET} || echo "$*"
}

# Verify pg_isready is available
if [[ ! -x "${PG_BIN}/pg_isready" ]]; then
    _say "ERROR: pg_isready not found at ${PG_BIN}/pg_isready"
    exit 1
fi

# Verify PG_DATA exists and looks like an initialised cluster
if [[ ! -f "${PG_DATA}/PG_VERSION" ]]; then
    _say "PostgreSQL data directory not initialised: ${PG_DATA}"
    exit 1
fi

# Check pg_ctl status (process-level)
if ! "${PG_BIN}/pg_ctl" status -D "${PG_DATA}" >/dev/null 2>&1; then
    _say "PostgreSQL process is not running"
    exit 1
fi

# Check TCP-level readiness (pg_isready contacts the postmaster)
if "${PG_BIN}/pg_isready" \
        -h "${DB_HOST}" \
        -p "${DB_PORT}" \
        -U postgres \
        -q; then
    _say "PostgreSQL is ready on ${DB_HOST}:${DB_PORT}"
    exit 0
else
    _say "PostgreSQL is not accepting connections on ${DB_HOST}:${DB_PORT}"
    exit 1
fi
