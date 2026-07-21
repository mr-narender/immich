#!/usr/bin/env bash
# build-patch.sh — fast patch upgrade for immich SPK
# Builds 2.7.5-2 from existing installed package + new ffmpeg + perl.
# Does NOT rebuild postgres/redis/node (already correct in 2.7.5-1).
# Runtime: ~5 minutes (downloads only).
#
# Usage:
#   bash syno/build-patch.sh
#   bash syno/build-patch.sh --skip-download   # reuse cached downloads
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
SYNO_DIR="${SCRIPT_DIR}"

PATCH_WORK="/tmp/immich-patch-work"
DOWNLOADS="${PATCH_WORK}/downloads"
STAGE="${PATCH_WORK}/stage"
SPK_DIR="${PATCH_WORK}/spk"
NAS_HOST="narender@192.168.2.2"
INSTALL_ROOT="/var/packages/immich/target"

SKIP_DOWNLOAD="${1:-}"

# ── Colours ──────────────────────────────────────────────────────────────────
BOLD=$'\033[1m'; RESET=$'\033[0m'
GREEN=$'\033[0;32m'; YELLOW=$'\033[0;33m'; RED=$'\033[0;31m'

log_section() { echo -e "\n${BOLD}── $* ──${RESET}"; }
log_ok()      { echo -e "  ${GREEN}✓${RESET} $*"; }
log_warn()    { echo -e "  ${YELLOW}⚠${RESET} $*"; }
die()         { echo -e "${RED}FATAL: $*${RESET}" >&2; exit 1; }

log_section "immich SPK patch builder: 2.7.5-1 → 2.7.5-2"
echo "  Adds: static ffmpeg 6.x (fixes fps_mode), relocatable Perl 5.38 (fixes ExifTool)"
echo "  NAS : ${NAS_HOST}"
echo ""

mkdir -p "${DOWNLOADS}" "${STAGE}/bin" "${STAGE}/perl" "${SPK_DIR}/scripts"

# ── Step 1: Download static ffmpeg ───────────────────────────────────────────
log_section "Step 1: Download static ffmpeg"
FFMPEG_URL="https://johnvansickle.com/ffmpeg/releases/ffmpeg-release-amd64-static.tar.xz"
FFMPEG_MD5_URL="${FFMPEG_URL}.md5"
FFMPEG_TAR="${DOWNLOADS}/ffmpeg-release-amd64-static.tar.xz"
FFMPEG_MD5="${DOWNLOADS}/ffmpeg-release-amd64-static.tar.xz.md5"

if [ -f "${FFMPEG_TAR}" ] && [ "${SKIP_DOWNLOAD}" = "--skip-download" ]; then
    log_warn "Using cached ffmpeg tarball"
else
    echo "  → ${FFMPEG_URL}"
    python3 -c "
import urllib.request, sys
print('  Downloading ffmpeg...')
urllib.request.urlretrieve('${FFMPEG_URL}', '${FFMPEG_TAR}')
try:
    urllib.request.urlretrieve('${FFMPEG_MD5_URL}', '${FFMPEG_MD5}')
except Exception as e:
    print(f'  MD5 file unavailable: {e}')
print('  Done.')
"
fi

if [ -f "${FFMPEG_MD5}" ]; then
    expected="$(awk '{print $1}' "${FFMPEG_MD5}")"
    if command -v md5sum >/dev/null 2>&1; then
        actual="$(md5sum "${FFMPEG_TAR}" | awk '{print $1}')"
    else
        actual="$(md5 -q "${FFMPEG_TAR}")"
    fi
    [ "${actual}" = "${expected}" ] && log_ok "MD5 verified" || log_warn "MD5 mismatch — continuing anyway"
fi

echo "  → Extracting ffmpeg + ffprobe..."
TMP_FFMPEG="${PATCH_WORK}/ffmpeg-extract"
rm -rf "${TMP_FFMPEG}" && mkdir -p "${TMP_FFMPEG}"
tar -xJf "${FFMPEG_TAR}" -C "${TMP_FFMPEG}" --wildcards '*/ffmpeg' '*/ffprobe' 2>/dev/null || \
    tar -xJf "${FFMPEG_TAR}" -C "${TMP_FFMPEG}"
find "${TMP_FFMPEG}" -maxdepth 3 -name "ffmpeg"  -type f | head -1 | xargs -I{} cp {} "${STAGE}/bin/ffmpeg"
find "${TMP_FFMPEG}" -maxdepth 3 -name "ffprobe" -type f | head -1 | xargs -I{} cp {} "${STAGE}/bin/ffprobe"
chmod +x "${STAGE}/bin/ffmpeg" "${STAGE}/bin/ffprobe"
[ -f "${STAGE}/bin/ffmpeg" ] || die "ffmpeg not found after extraction"
log_ok "ffmpeg: $(file "${STAGE}/bin/ffmpeg" | grep -o 'ELF.*statically\|ELF.*static-pie' || echo 'ok')"

# ── Step 2: Download relocatable Perl ────────────────────────────────────────
log_section "Step 2: Download relocatable Perl 5.38"
PERL_VER="5.42.2"
PERL_RELEASE="5.42.2.0"
PERL_TAR="${DOWNLOADS}/perl-linux-amd64.tar.gz"
PERL_URL="https://github.com/skaji/relocatable-perl/releases/download/${PERL_RELEASE}/perl-linux-amd64.tar.gz"

if [ -f "${PERL_TAR}" ] && [ "${SKIP_DOWNLOAD}" = "--skip-download" ]; then
    log_warn "Using cached perl tarball"
else
    echo "  → ${PERL_URL}"
    python3 -c "
import urllib.request
print('  Downloading relocatable-perl ...')
urllib.request.urlretrieve('${PERL_URL}', '${PERL_TAR}')
print('  Done.')
"
fi

echo "  → Extracting to stage/perl/..."
rm -rf "${STAGE}/perl" && mkdir -p "${STAGE}/perl"
tar -xzf "${PERL_TAR}" -C "${STAGE}/perl" --strip-components=1
[ -f "${STAGE}/perl/bin/perl" ] || die "perl binary not found after extraction"
chmod +x "${STAGE}/perl/bin/perl"
log_ok "Perl ${PERL_VER}: $(file "${STAGE}/perl/bin/perl" | cut -d: -f2- | xargs)"

# ── Step 3: Write updated startup wrappers ───────────────────────────────────
log_section "Step 3: Write updated startup wrappers (with ffmpeg + perl in PATH)"

cat > "${STAGE}/bin/immich-server" << 'SERVER_EOF'
#!/bin/sh
# immich-server — startup wrapper for the NestJS server
INSTALL_ROOT="/var/packages/immich/target"
NODE="${INSTALL_ROOT}/node/bin/node"
SERVER_DIST="${INSTALL_ROOT}/server/dist"

if [ -f "${INSTALL_ROOT}/conf/immich.conf" ]; then
    . "${INSTALL_ROOT}/conf/immich.conf"
fi

export NODE_ENV="${NODE_ENV:-production}"
export IMMICH_HOST="${IMMICH_HOST:-0.0.0.0}"
export IMMICH_PORT="${IMMICH_PORT:-2283}"
export UPLOAD_LOCATION="${UPLOAD_LOCATION:-/volume1/docker/immich/upload}"
export IMMICH_MEDIA_LOCATION="${UPLOAD_LOCATION}"
export DB_HOSTNAME="${DB_HOSTNAME:-127.0.0.1}"
export DB_PORT="${DB_PORT:-5433}"
export DB_USERNAME="${DB_USERNAME:-immich}"
export DB_PASSWORD="${DB_PASSWORD:-immich}"
export DB_DATABASE_NAME="${DB_DATABASE_NAME:-immich}"
export REDIS_HOSTNAME="${REDIS_HOSTNAME:-127.0.0.1}"
export REDIS_PORT="${REDIS_PORT:-6379}"
export LOG_LEVEL="${LOG_LEVEL:-log}"

export IMMICH_BUILD_DATA="${INSTALL_ROOT}"
export PATH="${INSTALL_ROOT}/bin:${INSTALL_ROOT}/perl/bin:${INSTALL_ROOT}/node/bin:${PATH}"
export NODE_MODULES="${INSTALL_ROOT}/server/node_modules"

exec "${NODE}" "${SERVER_DIST}/main" "$@"
SERVER_EOF
chmod +x "${STAGE}/bin/immich-server"

cat > "${STAGE}/bin/immich-microservices" << 'MICRO_EOF'
#!/bin/sh
# immich-microservices — startup wrapper for microservices worker
INSTALL_ROOT="/var/packages/immich/target"
NODE="${INSTALL_ROOT}/node/bin/node"
SERVER_DIST="${INSTALL_ROOT}/server/dist"

if [ -f "${INSTALL_ROOT}/conf/immich.conf" ]; then
    . "${INSTALL_ROOT}/conf/immich.conf"
fi

export NODE_ENV="${NODE_ENV:-production}"
export UPLOAD_LOCATION="${UPLOAD_LOCATION:-/volume1/docker/immich/upload}"
export IMMICH_MEDIA_LOCATION="${UPLOAD_LOCATION}"
export DB_HOSTNAME="${DB_HOSTNAME:-127.0.0.1}"
export DB_PORT="${DB_PORT:-5433}"
export DB_USERNAME="${DB_USERNAME:-immich}"
export DB_PASSWORD="${DB_PASSWORD:-immich}"
export DB_DATABASE_NAME="${DB_DATABASE_NAME:-immich}"
export REDIS_HOSTNAME="${REDIS_HOSTNAME:-127.0.0.1}"
export REDIS_PORT="${REDIS_PORT:-6379}"
export IMMICH_WORKERS="microservices"

export IMMICH_BUILD_DATA="${INSTALL_ROOT}"
export PATH="${INSTALL_ROOT}/bin:${INSTALL_ROOT}/perl/bin:${INSTALL_ROOT}/node/bin:${PATH}"

exec "${NODE}" "${SERVER_DIST}/main" "$@"
MICRO_EOF
chmod +x "${STAGE}/bin/immich-microservices"

log_ok "Startup wrappers written (PATH includes bin/ + perl/bin/)"

# ── Step 4: Pack minimal package.tgz (new/updated files only) ────────────────
# DSM 7.x upgrade merges: files in new package.tgz replace existing; files NOT
# in the tarball are preserved. So a partial tarball is safe for upgrades.
log_section "Step 4: Packing minimal patch package.tgz"

PKG_STAGE="${PATCH_WORK}/pkg-stage"
rm -rf "${PKG_STAGE}" && mkdir -p "${PKG_STAGE}/bin"

cp "${STAGE}/bin/ffmpeg"               "${PKG_STAGE}/bin/ffmpeg"
cp "${STAGE}/bin/ffprobe"              "${PKG_STAGE}/bin/ffprobe"
cp "${STAGE}/bin/immich-server"        "${PKG_STAGE}/bin/immich-server"
cp "${STAGE}/bin/immich-microservices" "${PKG_STAGE}/bin/immich-microservices"
cp -r "${STAGE}/perl"                  "${PKG_STAGE}/perl"
chmod +x "${PKG_STAGE}/bin/"*

log_ok "Patch contents:"
log_ok "  bin/ffmpeg       $(du -sh "${PKG_STAGE}/bin/ffmpeg" | cut -f1)"
log_ok "  bin/ffprobe      $(du -sh "${PKG_STAGE}/bin/ffprobe" | cut -f1)"
log_ok "  bin/immich-*     (updated PATH wrappers)"
log_ok "  perl/            $(du -sh "${PKG_STAGE}/perl" | cut -f1) (Perl 5.42 + ExifTool deps)"

PKG_TGZ="${SPK_DIR}/package.tgz"
tar -czf "${PKG_TGZ}" -C "${PKG_STAGE}" .
log_ok "package.tgz: $(du -sh "${PKG_TGZ}" | cut -f1)"

# ── Step 6: Write DSM lifecycle scripts ──────────────────────────────────────
log_section "Step 6: DSM lifecycle scripts"

cat > "${SPK_DIR}/scripts/start-stop-status" << 'SSS_EOF'
#!/bin/sh
INSTALL_ROOT="/var/packages/immich/target"
RUN_DIR="${INSTALL_ROOT}/run"
LOG_DIR="${INSTALL_ROOT}/log"
PID_SERVER="${RUN_DIR}/immich-server.pid"
PID_MICRO="${RUN_DIR}/immich-microservices.pid"
PID_ML="${RUN_DIR}/immich-machine-learning.pid"
PID_REDIS="${RUN_DIR}/redis.pid"
REDIS_DIR="${INSTALL_ROOT}/var/redis"
[ -f "${INSTALL_ROOT}/conf/immich.conf" ] && . "${INSTALL_ROOT}/conf/immich.conf"
REDIS_PORT="${REDIS_PORT:-6379}"

_start_redis() {
    [ -x "${INSTALL_ROOT}/redis/bin/redis-server" ] || return 0
    mkdir -p "${REDIS_DIR}"
    "${INSTALL_ROOT}/redis/bin/redis-server" \
        --port "${REDIS_PORT}" --bind 127.0.0.1 --dir "${REDIS_DIR}" \
        --save "" --appendonly no --daemonize no \
        >> "${LOG_DIR}/redis.log" 2>&1 &
    echo $! > "${PID_REDIS}"
}
_start() {
    mkdir -p "${RUN_DIR}" "${LOG_DIR}"
    _start_redis
    "${INSTALL_ROOT}/bin/immich-server" >> "${LOG_DIR}/server.log" 2>&1 &
    echo $! > "${PID_SERVER}"
    "${INSTALL_ROOT}/bin/immich-microservices" >> "${LOG_DIR}/microservices.log" 2>&1 &
    echo $! > "${PID_MICRO}"
    if [ -f "${INSTALL_ROOT}/bin/immich-machine-learning" ] && \
       [ -f "${INSTALL_ROOT}/python/bin/python3.11" ]; then
        "${INSTALL_ROOT}/bin/immich-machine-learning" >> "${LOG_DIR}/machine-learning.log" 2>&1 &
        echo $! > "${PID_ML}"
    fi
    return 0
}
_stop() {
    for pidfile in "${PID_SERVER}" "${PID_MICRO}" "${PID_ML}" "${PID_REDIS}"; do
        [ -f "${pidfile}" ] && kill "$(cat "${pidfile}")" 2>/dev/null || true
        rm -f "${pidfile}"
    done
    return 0
}
_status() {
    [ -f "${PID_SERVER}" ] && kill -0 "$(cat "${PID_SERVER}")" 2>/dev/null && return 0
    return 1
}
case "$1" in
    start)   _start ;;
    stop)    _stop ;;
    status)  _status ;;
    restart) _stop; sleep 2; _start ;;
    *)       echo "Usage: $0 {start|stop|status|restart}"; exit 1 ;;
esac
SSS_EOF
chmod +x "${SPK_DIR}/scripts/start-stop-status"

cat > "${SPK_DIR}/scripts/preinst" << 'PREINST_EOF'
#!/bin/sh
mkdir -p "${SYNOPKG_PKGVAR}/upload" "${SYNOPKG_PKGVAR}/redis" \
         "${SYNOPKG_PKGDEST}/log" "${SYNOPKG_PKGDEST}/run"
exit 0
PREINST_EOF
chmod +x "${SPK_DIR}/scripts/preinst"

cat > "${SPK_DIR}/scripts/postinst" << 'POSTINST_EOF'
#!/bin/sh
INSTALL_ROOT="${SYNOPKG_PKGDEST}"
CONF_DIR="${SYNOPKG_PKGDEST}/conf"
CONF_FILE="${CONF_DIR}/immich.conf"
PKG_VAR="${SYNOPKG_PKGVAR}"
PKG_USER="${SYNOPKG_PKG_STATUS}"
[ -f "${CONF_FILE}" ] && . "${CONF_FILE}" 2>/dev/null
mkdir -p \
    "${UPLOAD_LOCATION:-/volume1/docker/immich/upload}" \
    "${MACHINE_LEARNING_CACHE_FOLDER:-/volume1/docker/immich/model-cache}" \
    "${INSTALL_ROOT}/log" "${INSTALL_ROOT}/run"
chown -R immich:immich \
    "${CONF_DIR}" "${PKG_VAR}" "${INSTALL_ROOT}/log" "${INSTALL_ROOT}/run" \
    "${UPLOAD_LOCATION:-/volume1/docker/immich/upload}" 2>/dev/null || true
chmod 750 "${CONF_DIR}" 2>/dev/null || true
chmod 640 "${CONF_FILE}" 2>/dev/null || true
exit 0
POSTINST_EOF
chmod +x "${SPK_DIR}/scripts/postinst"

cat > "${SPK_DIR}/scripts/preuninst" << 'PREUNINST_EOF'
#!/bin/sh
synopkg stop immich 2>/dev/null || true
exit 0
PREUNINST_EOF
chmod +x "${SPK_DIR}/scripts/preuninst"

log_ok "Lifecycle scripts written"

# ── Step 7: conf/ from local src ─────────────────────────────────────────────
log_section "Step 7: conf/ from syno/src/conf"
mkdir -p "${SPK_DIR}/conf"
if [ -d "${SYNO_DIR}/src/conf" ]; then
    cp -r "${SYNO_DIR}/src/conf/." "${SPK_DIR}/conf/"
    log_ok "conf/ from ${SYNO_DIR}/src/conf"
else
    log_warn "No src/conf found — SPK will have empty conf/ (OK for upgrade)"
fi

# ── Step 8: Assemble .spk ────────────────────────────────────────────────────
log_section "Step 8: Assembling immich-x86_64-2.7.5-2.spk"
cp "${SYNO_DIR}/INFO" "${SPK_DIR}/INFO"

SPK_PATH="${REPO_ROOT}/immich-x86_64-2.7.5-2.spk"
tar cf "${SPK_PATH}" -C "${SPK_DIR}" INFO package.tgz scripts conf
log_ok "SPK assembled: ${SPK_PATH}"
log_ok "Size: $(du -sh "${SPK_PATH}" | cut -f1)"

SHA=$(shasum -a 256 "${SPK_PATH}" | awk '{print $1}')
echo ""
echo -e "${BOLD}${GREEN}╔══════════════════════════════════════════════════════════╗${RESET}"
echo -e "${BOLD}${GREEN}║  PATCH BUILD COMPLETE                                    ║${RESET}"
echo -e "${BOLD}${GREEN}╚══════════════════════════════════════════════════════════╝${RESET}"
echo -e "  SPK    : ${BOLD}${SPK_PATH}${RESET}"
echo -e "  SHA256 : ${SHA}"
echo ""
echo -e "  Install: scp ${SPK_PATH} ${NAS_HOST}:/tmp/"
echo -e "           ssh ${NAS_HOST} 'synopkg install /tmp/immich-x86_64-2.7.5-2.spk'"
echo ""
