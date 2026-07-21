#!/usr/bin/env bash
# service-setup.sh — sourced by spksrc-generated start-stop-status.sh
# Implements DSM7 package lifecycle hooks for Immich.
# Target: Synology DS923+ (x86_64), DSM 7.3.2
set -euo pipefail

# ---------------------------------------------------------------------------
# Package paths
# ---------------------------------------------------------------------------
PKG_DIR="/var/packages/immich/target"
PG_DIR="${PKG_DIR}/postgres"
PG_BIN="${PG_DIR}/bin"
NODE="${PKG_DIR}/node/bin/node"
PYTHON="${PKG_DIR}/python/bin/python"

PG_DATA="${SYNOPKG_PKGVAR}/pgdata"
IMMICH_LOG="${SYNOPKG_PKGVAR}/logs"
IMMICH_ENV_DIR="/etc/packages/immich"
IMMICH_ENV="${IMMICH_ENV_DIR}/immich.env"
IMMICH_BACKUP="${SYNOPKG_PKGVAR}/backup"

SERVER_DIR="${PKG_DIR}/server"
ML_DIR="${PKG_DIR}/machine-learning"

IMMICH_PORT=2283
ML_PORT=3003
PG_PORT=5432
REDIS_HOST="127.0.0.1"
REDIS_PORT=6379

DB_HOSTNAME="127.0.0.1"
DB_PORT="${PG_PORT}"
DB_DATABASE_NAME="immich"
DB_USERNAME="immich"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
_log() {
    echo "[immich] $*" >&2
}

_load_env() {
    if [[ -f "${IMMICH_ENV}" ]]; then
        # shellcheck source=/dev/null
        set -o allexport
        source "${IMMICH_ENV}"
        set +o allexport
    fi
}

_pg_running() {
    "${PG_BIN}/pg_ctl" status -D "${PG_DATA}" >/dev/null 2>&1
}

_pg_start() {
    _log "Starting PostgreSQL..."
    mkdir -p "${IMMICH_LOG}"
    "${PG_BIN}/pg_ctl" start \
        -D "${PG_DATA}" \
        -l "${IMMICH_LOG}/postgres.log" \
        -w \
        -t 60
}

_pg_stop() {
    _log "Stopping PostgreSQL..."
    "${PG_BIN}/pg_ctl" stop \
        -D "${PG_DATA}" \
        -m fast \
        -w \
        -t 60 \
        || true
}

_check_redis() {
    _log "Checking Redis connectivity at ${REDIS_HOST}:${REDIS_PORT}..."
    "${NODE}" -e "
        const net = require('net');
        const c = net.createConnection(${REDIS_PORT}, '${REDIS_HOST}');
        c.on('connect', () => { c.destroy(); process.exit(0); });
        c.on('error', () => process.exit(1));
        setTimeout(() => process.exit(1), 3000);
    " || {
        _log "ERROR: Redis is not reachable at ${REDIS_HOST}:${REDIS_PORT}. Install and start Redis from Package Center."
        return 1
    }
}

_psql() {
    # Run psql as the postgres superuser within the bundled cluster
    "${PG_BIN}/psql" -h "${DB_HOSTNAME}" -p "${DB_PORT}" -U postgres "$@"
}

_wait_pg_accept() {
    local retries=30
    while [[ ${retries} -gt 0 ]]; do
        if "${PG_BIN}/pg_isready" -h "${DB_HOSTNAME}" -p "${DB_PORT}" -U postgres >/dev/null 2>&1; then
            return 0
        fi
        sleep 1
        (( retries-- ))
    done
    _log "ERROR: PostgreSQL did not become ready in time"
    return 1
}

_ml_enabled() {
    _load_env
    [[ "${MACHINE_LEARNING_ENABLED:-false}" == "true" ]]
}

# ---------------------------------------------------------------------------
# SERVICE_COMMAND — primary service (immich-server)
# spksrc start-stop-status.sh will wrap this in a daemon loop / SVC_PIDFILE.
# ---------------------------------------------------------------------------
export SERVICE_COMMAND="${NODE} ${SERVER_DIR}/dist/main.js"
export SVC_BACKGROUND="yes"
export SVC_WRITE_PID="yes"

# ---------------------------------------------------------------------------
# Hook: service_prestart
# Called by start-stop-status.sh before launching SERVICE_COMMAND.
# ---------------------------------------------------------------------------
service_prestart() {
    _log "service_prestart: preparing Immich..."

    # 1. Load persisted env
    _load_env

    # 2. Ensure PostgreSQL is running
    if ! _pg_running; then
        _pg_start
    fi
    _wait_pg_accept

    # 3. Verify Redis is reachable
    _check_redis

    # 4. Export all immich env vars into the current shell (inherited by SERVICE_COMMAND)
    export DB_HOSTNAME="${DB_HOSTNAME}"
    export DB_PORT="${DB_PORT}"
    export DB_DATABASE_NAME="${DB_DATABASE_NAME}"
    export DB_USERNAME="${DB_USERNAME}"
    export DB_PASSWORD="${DB_PASSWORD:-}"
    export DB_VECTOR_EXTENSION="pgvector"
    export REDIS_HOSTNAME="${REDIS_HOST}"
    export REDIS_PORT="${REDIS_PORT}"
    export UPLOAD_LOCATION="${UPLOAD_LOCATION:-/volume1/immich}"
    export IMMICH_MEDIA_LOCATION="${UPLOAD_LOCATION:-/volume1/immich}"
    export IMMICH_MACHINE_LEARNING_URL="http://127.0.0.1:${ML_PORT}"
    export MACHINE_LEARNING_ENABLED="${MACHINE_LEARNING_ENABLED:-false}"
    export NODE_ENV="production"
    export IMMICH_LOG_LEVEL="${IMMICH_LOG_LEVEL:-log}"

    # Change to server dir so relative paths in dist/main.js resolve
    cd "${SERVER_DIR}"

    # 5. Optionally start ML service
    if _ml_enabled; then
        _log "service_prestart: starting ML service..."
        cd "${ML_DIR}"
        "${PYTHON}" -m immich_ml \
            --host 127.0.0.1 \
            --port "${ML_PORT}" \
            >> "${IMMICH_LOG}/machine-learning.log" 2>&1 &
        echo $! > "${SYNOPKG_PKGVAR}/machine-learning.pid"
        cd "${SERVER_DIR}"
        _log "service_prestart: ML service started (pid=$(cat ${SYNOPKG_PKGVAR}/machine-learning.pid))"
    fi

    _log "service_prestart: done"
}

# ---------------------------------------------------------------------------
# Hook: service_poststop
# Called after immich-server process is killed.
# ---------------------------------------------------------------------------
service_poststop() {
    _log "service_poststop: tearing down..."

    # Stop ML if running
    if [[ -f "${SYNOPKG_PKGVAR}/machine-learning.pid" ]]; then
        local ml_pid
        ml_pid=$(cat "${SYNOPKG_PKGVAR}/machine-learning.pid" 2>/dev/null || true)
        if [[ -n "${ml_pid}" ]] && kill -0 "${ml_pid}" 2>/dev/null; then
            _log "service_poststop: stopping ML service (pid=${ml_pid})..."
            kill "${ml_pid}" || true
            # Wait up to 10s
            local i=0
            while kill -0 "${ml_pid}" 2>/dev/null && [[ $i -lt 10 ]]; do
                sleep 1; (( i++ ))
            done
            kill -9 "${ml_pid}" 2>/dev/null || true
        fi
        rm -f "${SYNOPKG_PKGVAR}/machine-learning.pid"
    fi

    # Stop PostgreSQL
    _pg_stop

    _log "service_poststop: done"
}

# ---------------------------------------------------------------------------
# Hook: service_postinst
# Called once after package installation completes.
# ---------------------------------------------------------------------------
service_postinst() {
    _log "service_postinst: initialising Immich..."

    # --- 1. Read wizard variables -----------------------------------------
    local upload_location="${WIZARD_UPLOAD_LOCATION:-/volume1/immich}"
    local db_password="${WIZARD_DB_PASSWORD:-}"
    local ml_enabled_raw="${WIZARD_ML_ENABLED:-no}"

    # Normalise ml_enabled to true/false
    local ml_enabled="false"
    if [[ "${ml_enabled_raw,,}" == "yes" || "${ml_enabled_raw,,}" == "true" ]]; then
        ml_enabled="true"
    fi

    # Generate a random password if wizard left it blank
    if [[ -z "${db_password}" ]]; then
        db_password=$(head -c 32 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c 24)
        _log "service_postinst: generated random DB password"
    fi

    # --- 2. Initialise PostgreSQL cluster (idempotent) --------------------
    mkdir -p "${PG_DATA}"
    chmod 700 "${PG_DATA}"

    if [[ ! -f "${PG_DATA}/PG_VERSION" ]]; then
        _log "service_postinst: running initdb..."
        "${PG_BIN}/initdb" \
            -D "${PG_DATA}" \
            -U postgres \
            --encoding=UTF8 \
            --locale=C
    else
        _log "service_postinst: pgdata already initialised, skipping initdb"
    fi

    # --- 3. Start PG, create role + db + extension -----------------------
    if ! _pg_running; then
        _pg_start
    fi
    _wait_pg_accept

    # Create role if it doesn't exist
    if ! _psql -tAc "SELECT 1 FROM pg_roles WHERE rolname='${DB_USERNAME}'" | grep -q 1; then
        _log "service_postinst: creating role '${DB_USERNAME}'..."
        _psql -c "CREATE ROLE ${DB_USERNAME} WITH LOGIN PASSWORD '${db_password}';"
    else
        _log "service_postinst: role '${DB_USERNAME}' already exists; updating password..."
        _psql -c "ALTER ROLE ${DB_USERNAME} WITH PASSWORD '${db_password}';"
    fi

    # Create database if it doesn't exist
    if ! _psql -tAc "SELECT 1 FROM pg_database WHERE datname='${DB_DATABASE_NAME}'" | grep -q 1; then
        _log "service_postinst: creating database '${DB_DATABASE_NAME}'..."
        _psql -c "CREATE DATABASE ${DB_DATABASE_NAME} OWNER ${DB_USERNAME} ENCODING 'UTF8';"
    else
        _log "service_postinst: database '${DB_DATABASE_NAME}' already exists"
    fi

    # Load pgvector extension
    _log "service_postinst: enabling pgvector extension..."
    _psql -d "${DB_DATABASE_NAME}" -c "CREATE EXTENSION IF NOT EXISTS vector;" || {
        _log "WARNING: pgvector extension not available; Immich smart search will fail until it is installed"
    }

    # --- 4. Write env file -----------------------------------------------
    mkdir -p "${IMMICH_ENV_DIR}"
    chmod 700 "${IMMICH_ENV_DIR}"

    _log "service_postinst: writing ${IMMICH_ENV}..."
    cat > "${IMMICH_ENV}" <<EOF
# Immich environment — managed by package installer
# Edit values here; they take effect on next package restart.

DB_HOSTNAME=${DB_HOSTNAME}
DB_PORT=${DB_PORT}
DB_DATABASE_NAME=${DB_DATABASE_NAME}
DB_USERNAME=${DB_USERNAME}
DB_PASSWORD=${db_password}
DB_VECTOR_EXTENSION=pgvector

REDIS_HOSTNAME=${REDIS_HOST}
REDIS_PORT=${REDIS_PORT}

UPLOAD_LOCATION=${upload_location}
IMMICH_MEDIA_LOCATION=${upload_location}

IMMICH_MACHINE_LEARNING_URL=http://127.0.0.1:${ML_PORT}
MACHINE_LEARNING_ENABLED=${ml_enabled}

NODE_ENV=production
IMMICH_LOG_LEVEL=log
EOF
    chmod 640 "${IMMICH_ENV}"
    chown root:immich "${IMMICH_ENV}"

    # --- 5. Create upload directory structure ----------------------------
    _log "service_postinst: creating upload directories under ${upload_location}..."
    for subdir in upload thumbs encoded-video library profile backups; do
        mkdir -p "${upload_location}/${subdir}"
    done
    chown -R immich:immich "${upload_location}" || true

    # --- 6. Create log dir -----------------------------------------------
    mkdir -p "${IMMICH_LOG}"
    chown -R immich:immich "${IMMICH_LOG}" || true

    # --- 7. Create backup dir --------------------------------------------
    mkdir -p "${IMMICH_BACKUP}"
    chown -R immich:immich "${IMMICH_BACKUP}" || true

    # --- 8. pg_dump compatibility symlink --------------------------------
    # Immich's DatabaseBackup job hardcodes /usr/lib/postgresql/14/bin/pg_dump
    # (Debian convention). On Synology the binary lives under ${PG_BIN}.
    mkdir -p /usr/lib/postgresql/14/bin
    ln -sf "${PG_BIN}/pg_dump" /usr/lib/postgresql/14/bin/pg_dump
    _log "service_postinst: pg_dump symlink → /usr/lib/postgresql/14/bin/pg_dump"

    # --- 9. Deploy config UI to persistent location ----------------------
    # PKG_VAR survives reboots; INSTALL_ROOT/config-ui is bundled in the SPK.
    _log "service_postinst: deploying config UI..."
    mkdir -p "${SYNOPKG_PKGVAR}/config-ui"
    if [[ -d "${PKG_DIR}/config-ui" ]]; then
        cp "${PKG_DIR}/config-ui/server.cjs" "${SYNOPKG_PKGVAR}/config-ui/" 2>/dev/null || true
        cp "${PKG_DIR}/config-ui/index.html" "${SYNOPKG_PKGVAR}/config-ui/" 2>/dev/null || true
        chown -R immich:immich "${SYNOPKG_PKGVAR}/config-ui" || true
        _log "service_postinst: config UI → ${SYNOPKG_PKGVAR}/config-ui/"
    else
        _log "service_postinst: WARNING — ${PKG_DIR}/config-ui not found, skipping"
    fi

    _log "service_postinst: done"
}

# ---------------------------------------------------------------------------
# Hook: service_preuninst
# Called before package removal. Stop services, optionally keep data.
# ---------------------------------------------------------------------------
service_preuninst() {
    _log "service_preuninst: pre-uninstall cleanup..."
    _pg_stop || true
    _log "service_preuninst: done"
}

# ---------------------------------------------------------------------------
# Hook: service_save  (backup)
# Called by DSM backup framework / user-triggered package backup.
# ---------------------------------------------------------------------------
service_save() {
    _load_env

    local stamp
    stamp=$(date +%Y%m%d_%H%M%S)
    local dump_file="${IMMICH_BACKUP}/dump_${stamp}.sql"

    mkdir -p "${IMMICH_BACKUP}"

    if ! _pg_running; then
        _pg_start
        _wait_pg_accept
    fi

    _log "service_save: dumping database to ${dump_file}..."
    "${PG_BIN}/pg_dumpall" \
        -h "${DB_HOSTNAME}" \
        -p "${DB_PORT}" \
        -U postgres \
        > "${dump_file}"

    # Keep only the 5 most recent dumps to save disk space
    find "${IMMICH_BACKUP}" -maxdepth 1 -name 'dump_*.sql' \
        | sort -r \
        | tail -n +6 \
        | xargs -r rm -f

    _log "service_save: backup complete → ${dump_file}"
}

# ---------------------------------------------------------------------------
# Hook: service_restore  (restore)
# Called by DSM restore / user-triggered package restore.
# ---------------------------------------------------------------------------
service_restore() {
    _load_env

    # Find the most recent dump
    local dump_file
    dump_file=$(find "${IMMICH_BACKUP}" -maxdepth 1 -name 'dump_*.sql' | sort -r | head -n 1)

    if [[ -z "${dump_file}" ]]; then
        _log "service_restore: ERROR — no dump file found in ${IMMICH_BACKUP}"
        return 1
    fi

    _log "service_restore: restoring from ${dump_file}..."

    if ! _pg_running; then
        _pg_start
        _wait_pg_accept
    fi

    # Drop and recreate the target database before restoring
    _psql -c "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname = '${DB_DATABASE_NAME}';" || true
    _psql -c "DROP DATABASE IF EXISTS ${DB_DATABASE_NAME};" || true
    _psql -c "CREATE DATABASE ${DB_DATABASE_NAME} OWNER ${DB_USERNAME} ENCODING 'UTF8';"

    "${PG_BIN}/psql" \
        -h "${DB_HOSTNAME}" \
        -p "${DB_PORT}" \
        -U postgres \
        -f "${dump_file}"

    _log "service_restore: restore complete from ${dump_file}"
}
