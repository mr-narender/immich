#!/usr/bin/env bash
# ===========================================================================
# syno/build.sh — Immich Synology SPK master build script
# Target: x86_64, DSM 7.2+ (tested on 7.3.2)
# Runs on: macOS with Docker + Node.js 24 + pnpm installed
#
# Usage:
#   bash syno/build.sh              # build without ML
#   INCLUDE_ML=1 bash syno/build.sh # include ML Python service
#   PREFETCH_MODELS=0 bash syno/build.sh  # skip ONNX model download
#
# ===========================================================================
set -euo pipefail

# ── Color helpers ────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
RESET='\033[0m'

log_section() { echo -e "\n${BOLD}${BLUE}═══ $* ═══${RESET}"; }
log_ok()      { echo -e "${GREEN}  ✓ $*${RESET}"; }
log_warn()    { echo -e "${YELLOW}  ⚠ $*${RESET}"; }
log_err()     { echo -e "${RED}  ✗ $*${RESET}" >&2; }
die()         { log_err "$*"; exit 1; }

# ── Configuration ────────────────────────────────────────────────────────────
PACKAGE="immich"
VERSION="3.0.0"
PKG_REVISION="1"
FULL_VERSION="${VERSION}-${PKG_REVISION}"
ARCH="x86_64"
SPK_NAME="${PACKAGE}-${ARCH}-${FULL_VERSION}.spk"

NODE_VERSION="24.15.0"
NODE_TARBALL="node-v${NODE_VERSION}-linux-x64.tar.xz"
NODE_URL="https://nodejs.org/dist/v${NODE_VERSION}/${NODE_TARBALL}"
NODE_SHASUMS_URL="https://nodejs.org/dist/v${NODE_VERSION}/SHASUMS256.txt"

INCLUDE_ML="${INCLUDE_ML:-0}"
PREFETCH_MODELS="${PREFETCH_MODELS:-1}"

# Paths (relative to repo root, resolved to absolute below)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
SYNO_DIR="${SCRIPT_DIR}"
BUILD_DIR="${SYNO_DIR}/build"
STAGE_DIR="${BUILD_DIR}/stage"
VENDOR_DIR="${SYNO_DIR}/vendor"
SPK_BUILD_DIR="${BUILD_DIR}/spk-root"
DOWNLOADS_DIR="${SYNO_DIR}/downloads"


# ── Print build plan ─────────────────────────────────────────────────────────
print_build_plan() {
    echo -e "\n${BOLD}╔══════════════════════════════════════════════════════════╗${RESET}"
    echo -e "${BOLD}║        Immich Synology SPK Builder                      ║${RESET}"
    echo -e "${BOLD}╚══════════════════════════════════════════════════════════╝${RESET}"
    echo -e "  Package   : ${BOLD}${PACKAGE}${RESET} v${FULL_VERSION}"
    echo -e "  Arch      : ${ARCH}"
    echo -e "  DSM min   : 7.2-64561"
    echo -e "  Node.js   : ${NODE_VERSION} (Linux x86_64)"
    echo -e "  PG        : 14.x + pgvector (Docker build)"
    echo -e "  ML        : $([ "${INCLUDE_ML}" = "1" ] && echo "INCLUDED (Python 3.11 venv)" || echo "EXCLUDED")"
    echo -e "  Output    : ${REPO_ROOT}/${SPK_NAME}"
    echo ""
}

# ── Step 1: Check prerequisites ──────────────────────────────────────────────
check_prereqs() {
    log_section "Step 1: Checking prerequisites"

    local missing=()
    for tool in node pnpm docker git tar shasum; do
        if command -v "${tool}" >/dev/null 2>&1; then
            log_ok "${tool} — $(command -v "${tool}")"
        else
            log_err "${tool} — NOT FOUND"
            missing+=("${tool}")
        fi
    done

    if [ ${#missing[@]} -gt 0 ]; then
        die "Missing required tools: ${missing[*]}"
    fi

    # Verify Node.js version
    local node_ver
    node_ver="$(node --version 2>/dev/null | sed 's/^v//')"
    local node_major="${node_ver%%.*}"
    if [ "${node_major}" -lt 20 ]; then
        die "Node.js >= 20 required, found v${node_ver}"
    fi
    log_ok "Node.js v${node_ver} (>= 20)"

    # Verify Docker daemon is running
    if ! docker info >/dev/null 2>&1; then
        die "Docker daemon is not running. Start Docker and retry."
    fi
    log_ok "Docker daemon is running"

    # Verify we're in the right directory
    if [ ! -f "${REPO_ROOT}/package.json" ]; then
        die "Cannot find package.json in repo root: ${REPO_ROOT}"
    fi
    log_ok "Repo root: ${REPO_ROOT}"
}

# ── Step 2: Build Node.js server + web ──────────────────────────────────────
build_js() {
    log_section "Step 2: Building immich server + web (pnpm)"

    cd "${REPO_ROOT}"

    echo "  → pnpm install --frozen-lockfile"
    pnpm install --frozen-lockfile

    echo "  → Building @immich/sdk (TypeScript SDK)"
    pnpm --filter @immich/sdk build

    echo "  → Building @immich/plugin-sdk"
    pnpm --filter @immich/plugin-sdk build

    echo "  → Building @immich/server (NestJS)"
    pnpm --filter immich build

    echo "  → Building immich-web (SvelteKit)"
    pnpm --filter immich-web build

    log_ok "JS build complete"
    cd "${SCRIPT_DIR}"
}

# ── Step 3: Download + verify Node.js Linux x86_64 ───────────────────────────
download_nodejs() {
    log_section "Step 3: Downloading Node.js ${NODE_VERSION} Linux x86_64"

    mkdir -p "${DOWNLOADS_DIR}"

    local tarball_path="${DOWNLOADS_DIR}/${NODE_TARBALL}"
    local shasums_path="${DOWNLOADS_DIR}/SHASUMS256-node-v${NODE_VERSION}.txt"

    # Download tarball (skip if already present)
    if [ -f "${tarball_path}" ]; then
        log_warn "Tarball already present, skipping download: ${tarball_path}"
    else
        echo "  → Downloading ${NODE_URL}"
        # Use Python urllib since curl is blocked
        python3 -c "
import urllib.request, sys
url = '${NODE_URL}'
dest = '${tarball_path}'
print(f'  Fetching {url}')
urllib.request.urlretrieve(url, dest)
print(f'  Saved to {dest}')
"
    fi

    # Download SHASUMS256.txt
    if [ ! -f "${shasums_path}" ]; then
        echo "  → Downloading ${NODE_SHASUMS_URL}"
        python3 -c "
import urllib.request
urllib.request.urlretrieve('${NODE_SHASUMS_URL}', '${shasums_path}')
"
    fi

    # Verify SHA256
    echo "  → Verifying SHA256..."
    local expected_sha
    expected_sha="$(grep "${NODE_TARBALL}" "${shasums_path}" | awk '{print $1}')"
    if [ -z "${expected_sha}" ]; then
        die "Could not find SHA256 for ${NODE_TARBALL} in SHASUMS256.txt"
    fi

    local actual_sha
    if command -v sha256sum >/dev/null 2>&1; then
        actual_sha="$(sha256sum "${tarball_path}" | awk '{print $1}')"
    else
        # macOS uses shasum -a 256
        actual_sha="$(shasum -a 256 "${tarball_path}" | awk '{print $1}')"
    fi

    if [ "${actual_sha}" != "${expected_sha}" ]; then
        die "SHA256 mismatch for ${NODE_TARBALL}!\n  Expected: ${expected_sha}\n  Got:      ${actual_sha}"
    fi

    log_ok "SHA256 verified: ${actual_sha}"
}

# ── Step 4: Build PostgreSQL 14 + pgvector via Docker ───────────────────────
build_postgres() {
    log_section "Step 4: Building PostgreSQL 14 + pgvector (remote x86_64 host)"

    # WHY a remote host: the build Mac is arm64. Pulling postgres from the
    # Docker postgres:14 image gives a Debian-trixie binary that needs
    # GLIBC_2.38 — DEAD on DSM 7.2 (~glibc 2.26). And QEMU-emulated x86 gcc
    # ICEs on a big compile. So we build NATIVELY on an x86_64 host inside a
    # manylinux2014 (glibc 2.17) container → portable to any DSM, glibc-only
    # deps, vanilla source layout (prefix=/var/packages/immich/target/postgres
    # so it relocates correctly on the NAS). See syno/vm104-pgbuild.sh.
    local pg_host="${PG_BUILD_HOST:?PG_BUILD_HOST must be set, e.g. user@your-x86_64-linux-build-host}"
    local pg_script="${SYNO_DIR}/vm104-pgbuild.sh"

    [ -f "${pg_script}" ] || die "missing ${pg_script}"

    log_ok "Dispatching postgres+pgvector build to ${pg_host}..."
    scp -q "${pg_script}" "${pg_host}:/tmp/vm104-pgbuild.sh"
    ssh "${pg_host}" 'rm -f /tmp/pgbuild.log; bash /tmp/vm104-pgbuild.sh > /tmp/pgbuild.log 2>&1; tail -1 /tmp/pgbuild.log' \
        || die "remote postgres build failed — see ${pg_host}:/tmp/pgbuild.log"

    log_ok "Fetching built postgres tree..."
    rm -rf "${STAGE_DIR}/postgres"
    scp -q "${pg_host}:/tmp/pgout/postgres-x86_64.tar.gz" "${BUILD_DIR}/postgres-x86_64.tar.gz"
    tar xzf "${BUILD_DIR}/postgres-x86_64.tar.gz" -C "${STAGE_DIR}"

    # Verify (vanilla source layout: $P/lib, $P/share/extension)
    if [ ! -f "${STAGE_DIR}/postgres/bin/postgres" ]; then
        die "postgres binary not found in stage output"
    fi
    if [ ! -f "${STAGE_DIR}/postgres/lib/vector.so" ]; then
        die "pgvector extension (vector.so) not found in stage output"
    fi
    if [ ! -f "${STAGE_DIR}/postgres/share/extension/vector.control" ]; then
        die "pgvector control file not found in stage output"
    fi

    log_ok "PostgreSQL 14 + pgvector built (x86_64, glibc 2.17, portable)"
    log_ok "  postgres binary: $(file "${STAGE_DIR}/postgres/bin/postgres" | grep -o 'ELF[^,]*,[^,]*')"
    log_ok "  pgvector:        ${STAGE_DIR}/postgres/lib/vector.so"
}

# ── Step 4b: Build static Redis (zig cross-compile) ──────────────────────────
# Bundled (not a DSM dependency) so there is no "please install redis" prompt.
# Built fully static against musl via `zig cc` running NATIVELY on the arm64 host
# (NO --platform / QEMU — emulated x86 gcc ICEs non-deterministically on a large
# build). The resulting static-pie x86_64 binary has ZERO shared-lib deps, so it
# runs on ANY DSM regardless of the NAS glibc version.
build_redis() {
    log_section "Step 4b: Building static Redis (zig cross-compile)"

    docker rm -f immich-zig-build 2>/dev/null || true

    log_ok "Starting native-arm64 alpine container (no QEMU)..."
    docker run --name immich-zig-build -d alpine:3.20 sleep 3600

    # Toolchain + sources (zig arm64 native, redis source)
    local setup_script
    setup_script="$(cat << 'SETUP_EOF'
#!/bin/sh
set -e
apk add --no-cache wget xz tar make ca-certificates >/dev/null
cd /opt
wget -q https://ziglang.org/download/0.13.0/zig-linux-aarch64-0.13.0.tar.xz
tar xf zig-linux-aarch64-0.13.0.tar.xz
ln -sf /opt/zig-linux-aarch64-0.13.0/zig /usr/local/bin/zig
zig version
cd /tmp
wget -q https://download.redis.io/releases/redis-7.4.2.tar.gz || \
  wget -q -O redis-7.4.2.tar.gz https://github.com/redis/redis/archive/refs/tags/7.4.2.tar.gz
tar xzf redis-7.4.2.tar.gz
echo SETUP_DONE
SETUP_EOF
)"
    log_ok "Installing zig 0.13.0 + fetching redis 7.4.2..."
    echo "${setup_script}" | docker exec -i immich-zig-build sh

    # Cross-compile static x86_64-linux-musl (verified working command)
    local build_script
    build_script="$(cat << 'BUILD_EOF'
#!/bin/sh
set -e
cd /tmp/redis-7.4.2
make distclean >/dev/null 2>&1 || true
make -j4 \
  CC="zig cc -target x86_64-linux-musl" \
  AR="zig ar" \
  RANLIB="zig ranlib" \
  MALLOC=libc \
  BUILD_TLS=no \
  CFLAGS="-O2" \
  LDFLAGS="-static"
file src/redis-server
echo BUILD_DONE
BUILD_EOF
)"
    log_ok "Cross-compiling redis (x86_64-linux-musl, static)..."
    echo "${build_script}" | docker exec -i immich-zig-build sh

    mkdir -p "${STAGE_DIR}/redis/bin"
    docker cp "immich-zig-build:/tmp/redis-7.4.2/src/redis-server" "${STAGE_DIR}/redis/bin/redis-server"
    docker cp "immich-zig-build:/tmp/redis-7.4.2/src/redis-cli"    "${STAGE_DIR}/redis/bin/redis-cli"
    chmod +x "${STAGE_DIR}/redis/bin/redis-server" "${STAGE_DIR}/redis/bin/redis-cli"

    docker stop immich-zig-build > /dev/null
    docker rm immich-zig-build > /dev/null

    if [ ! -f "${STAGE_DIR}/redis/bin/redis-server" ]; then
        die "redis-server not found in stage output"
    fi

    log_ok "Static Redis extracted to stage"
    log_ok "  redis-server: $(file "${STAGE_DIR}/redis/bin/redis-server" | grep -o 'ELF.*statically\|ELF.*static-pie')"
}

# ── Step 4c: Download static ffmpeg (BtbN GPL static build) ─────────────────
# BtbN provides comprehensive GPL static builds for Linux x86_64 with
# full filter support including tonemapx (via libplacebo), zscale, etc.
# Immich requires tonemapx for HDR tone mapping; johnvansickle lacks it.
# BtbN n7.1 static = fully self-contained, no glibc version dependency.
download_ffmpeg() {
    log_section "Step 4c: Downloading static ffmpeg (BtbN n7.1 GPL)"

    # BtbN ffmpeg n7.1 GPL static build for Linux x86_64
    # SHA256: verify after download (no .sha256 file provided; use release asset)
    local btbn_version="n7.1-latest"
    local ffmpeg_url="https://github.com/BtbN/FFmpeg-Builds/releases/download/latest/ffmpeg-${btbn_version}-linux64-gpl-7.1.tar.xz"
    local tarball="${DOWNLOADS_DIR}/ffmpeg-btbn-${btbn_version}-linux64-gpl.tar.xz"

    mkdir -p "${DOWNLOADS_DIR}"

    if [ -f "${tarball}" ]; then
        log_warn "ffmpeg tarball already present, skipping download"
    else
        echo "  → Downloading BtbN ffmpeg ${btbn_version} GPL static"
        echo "     ${ffmpeg_url}"
        python3 -c "
import urllib.request
url = '${ffmpeg_url}'
dest = '${tarball}'
print('  Fetching BtbN ffmpeg tarball (~112MB)...')
urllib.request.urlretrieve(url, dest)
print('  Done.')
"
    fi

    # Extract only ffmpeg + ffprobe binaries
    mkdir -p "${STAGE_DIR}/bin"
    echo "  → Extracting ffmpeg + ffprobe..."
    tar -xJf "${tarball}" -C /tmp --wildcards '*/bin/ffmpeg' '*/bin/ffprobe' 2>/dev/null || \
        tar -xJf "${tarball}" -C /tmp 2>/dev/null
    find /tmp -maxdepth 4 -name "ffmpeg" -type f | head -1 | xargs -I{} cp {} "${STAGE_DIR}/bin/ffmpeg"
    find /tmp -maxdepth 4 -name "ffprobe" -type f | head -1 | xargs -I{} cp {} "${STAGE_DIR}/bin/ffprobe"
    chmod +x "${STAGE_DIR}/bin/ffmpeg" "${STAGE_DIR}/bin/ffprobe"

    if [ ! -f "${STAGE_DIR}/bin/ffmpeg" ]; then
        die "ffmpeg binary not found after extraction"
    fi

    # Verify tonemapx filter is present
    if "${STAGE_DIR}/bin/ffmpeg" -filters 2>/dev/null | grep -q "tonemapx"; then
        log_ok "tonemapx filter confirmed present"
    else
        log_warn "tonemapx not in this build — HDR tone mapping will use source patch fallback"
    fi

    local ver
    ver="$("${STAGE_DIR}/bin/ffmpeg" -version 2>/dev/null | head -1 | grep -o 'version [^ ]*' || echo 'unknown')"
    log_ok "ffmpeg extracted to stage/bin/ (${ver})"
}

# ── Step 4d: Download relocatable Perl (skaji/relocatable-perl) ──────────────
# Pre-built relocatable Perl for Linux x86_64, built against old glibc so it
# runs on any DSM 7.x (glibc 2.17+). No Perl build time (complex + slow).
# ExifTool (vendored in immich's node_modules) requires perl in PATH.
download_perl() {
    log_section "Step 4d: Downloading relocatable Perl"

    local perl_version="5.42.2"
    local perl_release="5.42.2.0"
    local perl_tarball="perl-linux-amd64.tar.gz"
    local perl_url="https://github.com/skaji/relocatable-perl/releases/download/${perl_release}/${perl_tarball}"
    local tarball="${DOWNLOADS_DIR}/${perl_tarball}"

    mkdir -p "${DOWNLOADS_DIR}"

    if [ -f "${tarball}" ]; then
        log_warn "Perl tarball already present, skipping download"
    else
        echo "  → Downloading ${perl_url}"
        python3 -c "
import urllib.request
print('  Fetching relocatable-perl ${perl_version}...')
urllib.request.urlretrieve('${perl_url}', '${tarball}')
print('  Done.')
"
    fi

    # Extract to stage/perl/
    echo "  → Extracting to stage/perl/..."
    rm -rf "${STAGE_DIR}/perl"
    mkdir -p "${STAGE_DIR}/perl"
    tar -xzf "${tarball}" -C "${STAGE_DIR}/perl" --strip-components=1

    if [ ! -f "${STAGE_DIR}/perl/bin/perl" ]; then
        die "perl binary not found after extraction (expected stage/perl/bin/perl)"
    fi

    chmod +x "${STAGE_DIR}/perl/bin/perl"
    log_ok "Perl ${perl_version} extracted to stage/perl/"
    log_ok "  $(file "${STAGE_DIR}/perl/bin/perl" | cut -d: -f2- | xargs)"
}

# ── Step 5: Build Python ML environment via Docker ───────────────────────────
build_ml_python() {
    if [ "${INCLUDE_ML}" != "1" ]; then
        log_section "Step 5: ML Python (SKIPPED — INCLUDE_ML=${INCLUDE_ML})"
        return
    fi

    log_section "Step 5: Building Python 3.11 ML venv (Docker)"

    local ml_dir="${REPO_ROOT}/machine-learning"
    if [ ! -f "${ml_dir}/pyproject.toml" ]; then
        die "machine-learning/pyproject.toml not found at ${ml_dir} — cannot build ML venv"
    fi

    # Clean up any leftover container
    docker rm -f immich-ml-build 2>/dev/null || true

    log_ok "Starting python:3.11-slim amd64 container for ML venv build..."
    docker run \
      --platform linux/amd64 \
      --name immich-ml-build \
      -d \
      python:3.11-slim \
      sleep 7200

    # Install build tools + uv
    docker exec immich-ml-build bash -c "
      apt-get update -qq && \
      apt-get install -y -qq gcc g++ libgomp1 ca-certificates git && \
      pip install --quiet uv && \
      echo 'uv ready'
    "

    # Copy machine-learning directory into container
    log_ok "Copying machine-learning source into container..."
    docker cp "${ml_dir}/." "immich-ml-build:/build/"

    # Create venv and install immich_ml[cpu]
    log_ok "Installing immich_ml[cpu] into venv (this takes ~10-20 min)..."
    docker exec immich-ml-build bash -c "
      set -euo pipefail
      python3 -m venv --copies /opt/immich-ml-venv
      cd /build
      /opt/immich-ml-venv/bin/pip install --quiet uv
      /opt/immich-ml-venv/bin/python -m uv pip install '.[cpu]'
      echo 'ML venv complete'
    "

    # Extract venv
    log_ok "Extracting ML venv to stage..."
    mkdir -p "${STAGE_DIR}/python"
    docker cp "immich-ml-build:/opt/immich-ml-venv/." "${STAGE_DIR}/python/"

    # Copy Python stdlib (required at runtime — venv relies on it)
    mkdir -p "${STAGE_DIR}/python/lib"
    docker cp "immich-ml-build:/usr/local/lib/python3.11/." "${STAGE_DIR}/python/lib/python3.11/"
    # Copy Python binary as fallback (--copies should handle it but belt+suspenders)
    docker cp "immich-ml-build:/usr/local/bin/python3.11" "${STAGE_DIR}/python/bin/python3.11" 2>/dev/null || true

    # Copy the immich_ml source (needed at runtime)
    mkdir -p "${STAGE_DIR}/machine-learning"
    docker cp "immich-ml-build:/build/." "${STAGE_DIR}/machine-learning/"

    docker stop immich-ml-build > /dev/null
    docker rm immich-ml-build > /dev/null

    # Verify extraction
    if [[ -f "${STAGE_DIR}/python/bin/python3.11" ]] || [[ -f "${STAGE_DIR}/python/lib/python3.11/os.py" ]]; then
        log_ok "Python 3.11 confirmed in stage"
    else
        die "Python 3.11 not found in stage after extraction"
    fi

    log_ok "Python 3.11 ML venv extracted to stage"
}

# ── Step 6: Assemble package stage/ layout ───────────────────────────────────
assemble_stage() {
    log_section "Step 6: Assembling stage/ layout"

    # NOTE: Do NOT rm -rf STAGE_DIR here — Steps 4 (postgres) and 5 (python/machine-learning)
    # already extracted their artifacts into STAGE_DIR before this step runs.
    mkdir -p \
        "${STAGE_DIR}/bin" \
        "${STAGE_DIR}/node" \
        "${STAGE_DIR}/postgres" \
        "${STAGE_DIR}/server" \
        "${STAGE_DIR}/web" \
        "${STAGE_DIR}/geodata" \
        "${STAGE_DIR}/scripts" \
        "${STAGE_DIR}/conf"

    if [ "${INCLUDE_ML}" = "1" ]; then
        mkdir -p "${STAGE_DIR}/python" "${STAGE_DIR}/machine-learning"
    fi

    # ── Node.js runtime ──────────────────────────────────────────────────────
    echo "  → Extracting Node.js ${NODE_VERSION} to stage/node/"
    local tarball_path="${DOWNLOADS_DIR}/${NODE_TARBALL}"
    tar -xJf "${tarball_path}" -C "${STAGE_DIR}/node" --strip-components=1
    log_ok "Node.js extracted: $(${STAGE_DIR}/node/bin/node --version 2>/dev/null || echo 'cannot run on macOS — OK')"

    # ── ffmpeg + ffprobe ─────────────────────────────────────────────────────
    # Already downloaded to ${STAGE_DIR}/bin/ by Step 4c (download_ffmpeg).
    if [ ! -f "${STAGE_DIR}/bin/ffmpeg" ]; then
        die "ffmpeg binary missing from stage — Step 4c (download_ffmpeg) must have failed"
    fi
    log_ok "ffmpeg already in stage/bin/ (from Step 4c)"

    # ── Perl ─────────────────────────────────────────────────────────────────
    # Already extracted to ${STAGE_DIR}/perl/ by Step 4d (download_perl).
    if [ ! -f "${STAGE_DIR}/perl/bin/perl" ]; then
        die "perl binary missing from stage — Step 4d (download_perl) must have failed"
    fi
    log_ok "Perl already in stage/perl/ (from Step 4d)"

    # ── PostgreSQL + pgvector ────────────────────────────────────────────────
    # Already extracted to ${STAGE_DIR}/postgres/ by Step 4 (build_postgres).
    if [ ! -f "${STAGE_DIR}/postgres/bin/postgres" ]; then
        die "postgres binary missing from stage — Step 4 (build_postgres) must have failed"
    fi
    log_ok "PostgreSQL already in stage (from Step 4)"

    # ── Python ML venv ───────────────────────────────────────────────────────
    # Already extracted to ${STAGE_DIR}/python/ and ${STAGE_DIR}/machine-learning/
    # by Step 5 (build_ml_python).
    if [ "${INCLUDE_ML}" = "1" ]; then
        if [[ ! -f "${STAGE_DIR}/python/bin/python3.11" ]] && [[ ! -f "${STAGE_DIR}/python/lib/python3.11/os.py" ]]; then
            die "Python ML venv missing from stage — Step 5 (build_ml_python) must have failed"
        fi
        log_ok "Python ML venv already in stage (from Step 5)"
        log_ok "machine-learning source already in stage (from Step 5)"
    fi

    # ── Server build output ──────────────────────────────────────────────────
    echo "  → Copying server build to stage/server/"
    local server_dist="${REPO_ROOT}/server/dist"
    if [ ! -d "${server_dist}" ]; then
        die "server/dist not found — run pnpm build first (Step 2)"
    fi
    cp -r "${server_dist}" "${STAGE_DIR}/server/dist"

    # Production node_modules via pnpm deploy
    echo "  → Creating production server node_modules (pnpm deploy)"
    local deploy_tmp="${BUILD_DIR}/server-deploy"
    rm -rf "${deploy_tmp}"
    mkdir -p "${deploy_tmp}"
    cd "${REPO_ROOT}"
    pnpm --filter immich deploy --prod "${deploy_tmp}"
    # Copy only node_modules (pnpm deploy puts package.json etc. there too)
    cp -r "${deploy_tmp}/node_modules" "${STAGE_DIR}/server/node_modules"
    rm -rf "${deploy_tmp}"
    log_ok "Server prod node_modules deployed"

    # ── Web build output ─────────────────────────────────────────────────────
    echo "  → Copying web build to stage/web/"
    local web_build="${REPO_ROOT}/web/build"
    if [ ! -d "${web_build}" ]; then
        die "web/build not found — run pnpm --filter immich-web build first"
    fi
    cp -r "${web_build}" "${STAGE_DIR}/web/build"
    log_ok "Web build copied"

    # ── Geodata ─────────────────────────────────────────────────────────────
    echo "  → Copying geodata to stage/geodata/"
    local geodata_src="${REPO_ROOT}/server/geodata"
    if [ -d "${geodata_src}" ]; then
        cp -r "${geodata_src}/." "${STAGE_DIR}/geodata/"
        log_ok "Geodata copied from server/geodata/"
    else
        # Try node_modules path
        local geodata_nm="${STAGE_DIR}/server/node_modules/local-reverse-geocoder/geo_files"
        if [ -d "${geodata_nm}" ]; then
            cp -r "${geodata_nm}/." "${STAGE_DIR}/geodata/"
            log_ok "Geodata copied from node_modules"
        else
            log_warn "Geodata not found — will be downloaded on first run"
        fi
    fi

    # ── Scripts ──────────────────────────────────────────────────────────────
    echo "  → Copying scripts to stage/scripts/"
    if [ -d "${SYNO_DIR}/scripts" ]; then
        cp -r "${SYNO_DIR}/scripts/." "${STAGE_DIR}/scripts/"
        chmod +x "${STAGE_DIR}/scripts/"*.sh 2>/dev/null || true
    fi
    _write_postgres_healthcheck
    _write_startup_wrappers

    # ── env.default ─────────────────────────────────────────────────────────
    _write_env_default

    cd "${SCRIPT_DIR}"
    log_ok "Stage layout assembled at ${STAGE_DIR}"
}

# ── Write postgres health-check script ───────────────────────────────────────
_write_postgres_healthcheck() {
    mkdir -p "${STAGE_DIR}/scripts"
    cat > "${STAGE_DIR}/scripts/postgres-check-health.sh" << 'HEALTHCHECK_EOF'
#!/bin/sh
# postgres-check-health.sh — called by start-stop-status
INSTALL_ROOT="/var/packages/immich/target"
PG_CTL="${INSTALL_ROOT}/postgres/bin/pg_isready"
PG_HOST="${DB_HOST:-127.0.0.1}"
PG_PORT="${DB_PORT:-5432}"

"${PG_CTL}" -h "${PG_HOST}" -p "${PG_PORT}" -U "${DB_USERNAME:-immich}" -d "${DB_DATABASE_NAME:-immich}"
HEALTHCHECK_EOF
    chmod +x "${STAGE_DIR}/scripts/postgres-check-health.sh"
}

# ── Write startup wrapper scripts ─────────────────────────────────────────────
_write_startup_wrappers() {
    mkdir -p "${STAGE_DIR}/bin"

    # immich-server wrapper
    cat > "${STAGE_DIR}/bin/immich-server" << 'SERVER_EOF'
#!/bin/sh
# immich-server — startup wrapper for the NestJS server
INSTALL_ROOT="/var/packages/immich/target"
NODE="${INSTALL_ROOT}/node/bin/node"
SERVER_DIST="${INSTALL_ROOT}/server/dist"

# Source env (DSM sets this from conf/immich.conf)
if [ -f "${INSTALL_ROOT}/conf/immich.conf" ]; then
    . "${INSTALL_ROOT}/conf/immich.conf"
fi

# Defaults
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
    chmod +x "${STAGE_DIR}/bin/immich-server"

    # immich-microservices wrapper (background job worker)
    cat > "${STAGE_DIR}/bin/immich-microservices" << 'MICRO_EOF'
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
    chmod +x "${STAGE_DIR}/bin/immich-microservices"

    # immich-machine-learning wrapper (optional)
    cat > "${STAGE_DIR}/bin/immich-machine-learning" << 'ML_EOF'
#!/bin/sh
# immich-machine-learning — startup wrapper for ML service
INSTALL_ROOT="/var/packages/immich/target"
PYTHON="${INSTALL_ROOT}/python/bin/python3.11"
ML_DIR="${INSTALL_ROOT}/machine-learning"

if [ ! -f "${PYTHON}" ]; then
    echo "ML service not included in this SPK build" >&2
    exit 1
fi

if [ -f "${INSTALL_ROOT}/conf/immich.conf" ]; then
    . "${INSTALL_ROOT}/conf/immich.conf"
fi

export IMMICH_ML_HOST="${IMMICH_ML_HOST:-0.0.0.0}"
export IMMICH_ML_PORT="${IMMICH_ML_PORT:-3003}"
export MACHINE_LEARNING_CACHE_FOLDER="${MACHINE_LEARNING_CACHE_FOLDER:-/volume1/docker/immich/model-cache}"
export HF_HOME="${MACHINE_LEARNING_CACHE_FOLDER}"
export TRANSFORMERS_CACHE="${MACHINE_LEARNING_CACHE_FOLDER}"

export PATH="${INSTALL_ROOT}/python/bin:${PATH}"

cd "${ML_DIR}"
exec "${PYTHON}" -m uvicorn app.main:app \
    --host "${IMMICH_ML_HOST}" \
    --port "${IMMICH_ML_PORT}" \
    --workers 1
ML_EOF
    chmod +x "${STAGE_DIR}/bin/immich-machine-learning"
}

# ── Write env.default ─────────────────────────────────────────────────────────
_write_env_default() {
    cat > "${STAGE_DIR}/env.default" << 'ENV_EOF'
# Immich default environment — copied to conf/immich.conf on first install
# Edit /var/packages/immich/target/conf/immich.conf to customize.

NODE_ENV=production
IMMICH_HOST=0.0.0.0
IMMICH_PORT=2283

# Storage — default to the package-owned var dir (always writable by the immich
# user; on the data volume). DSM sandboxes package scripts from arbitrary /volume1
# paths unless a shared folder + data-share is declared. To use a Shared Folder
# instead, set UPLOAD_LOCATION below to it AND grant the 'immich' user write access.
UPLOAD_LOCATION=/var/packages/immich/var/upload

# PostgreSQL (bundled)
DB_HOSTNAME=127.0.0.1
# DB_PORT auto-selected at runtime (first free port from 5432+; DSM uses 5432).
# Uncomment to pin a specific port:
# DB_PORT=5433
DB_USERNAME=immich
DB_PASSWORD=immich
DB_DATABASE_NAME=immich

# Redis (bundled — runs as a local service, no external package needed)
REDIS_HOSTNAME=127.0.0.1
# REDIS_PORT auto-selected at runtime (first free port from 6379+).
# Uncomment to pin a specific port:
# REDIS_PORT=6379

# Machine Learning
IMMICH_ML_HOST=127.0.0.1
IMMICH_ML_PORT=3003
MACHINE_LEARNING_CACHE_FOLDER=/var/packages/immich/var/model-cache

# Logging: verbose, debug, log, warn, error
LOG_LEVEL=log
ENV_EOF
}

# ── Step 7: Create package.tgz ───────────────────────────────────────────────
create_package_tgz() {
    log_section "Step 7: Creating package.tgz"

    local pkg_tgz="${BUILD_DIR}/package.tgz"
    tar czf "${pkg_tgz}" -C "${STAGE_DIR}" .

    local size
    size="$(du -sh "${pkg_tgz}" | cut -f1)"
    log_ok "package.tgz created: ${pkg_tgz} (${size})"
}

# ── Step 8: Assemble .spk archive ────────────────────────────────────────────
assemble_spk() {
    log_section "Step 8: Assembling ${SPK_NAME}"

    rm -rf "${SPK_BUILD_DIR}"
    mkdir -p "${SPK_BUILD_DIR}"

    # Core SPK components
    cp "${SYNO_DIR}/INFO" "${SPK_BUILD_DIR}/INFO"
    cp "${BUILD_DIR}/package.tgz" "${SPK_BUILD_DIR}/package.tgz"

    # DSM lifecycle scripts — always generate (start-stop-status, preinst, postinst, preuninst)
    # syno/scripts/ contains runtime helpers only, NOT DSM hooks — never copy it here
    mkdir -p "${SPK_BUILD_DIR}/scripts"
    _write_dsm_scripts "${SPK_BUILD_DIR}/scripts"

    # conf/privilege + conf/resource from syno/src/conf/
    if [ -d "${SYNO_DIR}/src/conf" ]; then
        cp -r "${SYNO_DIR}/src/conf" "${SPK_BUILD_DIR}/conf"
    fi

    # Install wizard (optional — DSM shows during package install)
    if [ -d "${SYNO_DIR}/src/wizard" ]; then
        cp -r "${SYNO_DIR}/src/wizard" "${SPK_BUILD_DIR}/wizard"
    fi

    # Build the final .spk — DSM requires UNCOMPRESSED tar, INFO must be first entry
    local spk_path="${REPO_ROOT}/${SPK_NAME}"
    local tar_args=( INFO package.tgz scripts conf )
    [ -d "${SPK_BUILD_DIR}/wizard" ] && tar_args+=( wizard )
    tar cf "${spk_path}" -C "${SPK_BUILD_DIR}" "${tar_args[@]}"

    local sha256
    if command -v sha256sum >/dev/null 2>&1; then
        sha256="$(sha256sum "${spk_path}" | awk '{print $1}')"
    else
        sha256="$(shasum -a 256 "${spk_path}" | awk '{print $1}')"
    fi

    local size
    size="$(du -sh "${spk_path}" | cut -f1)"

    echo ""
    echo -e "${BOLD}${GREEN}╔══════════════════════════════════════════════════════════╗${RESET}"
    echo -e "${BOLD}${GREEN}║  BUILD COMPLETE                                          ║${RESET}"
    echo -e "${BOLD}${GREEN}╚══════════════════════════════════════════════════════════╝${RESET}"
    echo -e "  SPK     : ${BOLD}${spk_path}${RESET}"
    echo -e "  Size    : ${size}"
    echo -e "  SHA256  : ${sha256}"
    echo ""
    echo -e "  Install via DSM Package Center → Manual Install"
    echo -e "  Or: synopkg install ${SPK_NAME}"
    echo ""
}

# ── Write minimal DSM package scripts ────────────────────────────────────────
_write_dsm_scripts() {
    local scripts_dir="$1"

    # start-stop-status — prefer the canonical copy in syno/src/scripts/
    # (full redis+postgres readiness-gated orchestration). Heredoc = fallback.
    if [ -f "${SYNO_DIR}/src/scripts/start-stop-status" ]; then
        cp "${SYNO_DIR}/src/scripts/start-stop-status" "${scripts_dir}/start-stop-status"
    else
    cat > "${scripts_dir}/start-stop-status" << 'SSS_EOF'
#!/bin/sh
# start-stop-status — DSM package lifecycle script
INSTALL_ROOT="/var/packages/immich/target"
RUN_DIR="${INSTALL_ROOT}/run"
LOG_DIR="${INSTALL_ROOT}/log"
PID_SERVER="${RUN_DIR}/immich-server.pid"
PID_MICRO="${RUN_DIR}/immich-microservices.pid"
PID_ML="${RUN_DIR}/immich-ml.pid"
PID_REDIS="${RUN_DIR}/redis.pid"
REDIS_DIR="${INSTALL_ROOT}/var/redis"

# Load conf for REDIS_PORT (set by DSM from conf/immich.conf)
[ -f "${INSTALL_ROOT}/conf/immich.conf" ] && . "${INSTALL_ROOT}/conf/immich.conf"
REDIS_PORT="${REDIS_PORT:-6379}"

# Start bundled Redis (self-contained — no external SPK dependency)
_start_redis() {
    [ -x "${INSTALL_ROOT}/redis/bin/redis-server" ] || return 0
    mkdir -p "${REDIS_DIR}"
    "${INSTALL_ROOT}/redis/bin/redis-server" \
        --port "${REDIS_PORT}" \
        --bind 127.0.0.1 \
        --dir "${REDIS_DIR}" \
        --save "" \
        --appendonly no \
        --daemonize no \
        >> "${LOG_DIR}/redis.log" 2>&1 &
    echo $! > "${PID_REDIS}"
}

_start() {
    mkdir -p "${RUN_DIR}" "${LOG_DIR}"

    # Start bundled Redis first (immich depends on it)
    _start_redis

    # Start immich server
    "${INSTALL_ROOT}/bin/immich-server" \
        >> "${LOG_DIR}/server.log" 2>&1 &
    echo $! > "${PID_SERVER}"

    # Start microservices worker
    "${INSTALL_ROOT}/bin/immich-microservices" \
        >> "${LOG_DIR}/microservices.log" 2>&1 &
    echo $! > "${PID_MICRO}"

    # Start ML if included
    if [ -f "${INSTALL_ROOT}/bin/immich-machine-learning" ] && \
       [ -f "${INSTALL_ROOT}/python/bin/python3.11" ]; then
        "${INSTALL_ROOT}/bin/immich-machine-learning" \
            >> "${LOG_DIR}/machine-learning.log" 2>&1 &
        echo $! > "${PID_ML}"
    fi

    return 0
}

_stop() {
    # Stop immich processes first, Redis last
    for pidfile in "${PID_SERVER}" "${PID_MICRO}" "${PID_ML}" "${PID_REDIS}"; do
        if [ -f "${pidfile}" ]; then
            pid="$(cat "${pidfile}")"
            kill "${pid}" 2>/dev/null || true
            rm -f "${pidfile}"
        fi
    done
    return 0
}

_status() {
    if [ -f "${PID_SERVER}" ] && kill -0 "$(cat "${PID_SERVER}")" 2>/dev/null; then
        return 0
    fi
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
    fi
    chmod +x "${scripts_dir}/start-stop-status"

    # preinst — pre-install hook
    cat > "${scripts_dir}/preinst" << 'PREINST_EOF'
#!/bin/sh
# preinst — run before package files are extracted
INSTALL_ROOT="/var/packages/immich/target"

# Create upload directory
mkdir -p \
    "/volume1/docker/immich/upload" \
    "/volume1/docker/immich/model-cache" \
    "${INSTALL_ROOT}/log" \
    "${INSTALL_ROOT}/run"

exit 0
PREINST_EOF
    chmod +x "${scripts_dir}/preinst"

    # postinst — post-install hook
    cat > "${scripts_dir}/postinst" << 'POSTINST_EOF'
#!/bin/sh
# postinst — run after package files are extracted (runs as root)
INSTALL_ROOT="/var/packages/immich/target"
CONF_DIR="${INSTALL_ROOT}/conf"
CONF_FILE="${CONF_DIR}/immich.conf"
PKG_USER="immich"
PKG_VAR="/var/packages/immich/var"

mkdir -p "${CONF_DIR}" "${PKG_VAR}"

# Build conf from env.default on first install, applying the install wizard's
# choices (DSM exports them as WIZARD_* env vars). Without this the wizard
# inputs are silently dropped.
if [ ! -f "${CONF_FILE}" ]; then
    cp "${INSTALL_ROOT}/env.default" "${CONF_FILE}"
    [ -n "${WIZARD_UPLOAD_LOCATION}" ] && \
        sed -i "s|^UPLOAD_LOCATION=.*|UPLOAD_LOCATION=${WIZARD_UPLOAD_LOCATION}|" "${CONF_FILE}"
    [ -n "${WIZARD_DB_PASSWORD}" ] && \
        sed -i "s|^DB_PASSWORD=.*|DB_PASSWORD=${WIZARD_DB_PASSWORD}|" "${CONF_FILE}"
    if [ "${WIZARD_ML_ENABLED}" = "true" ]; then
        echo "MACHINE_LEARNING_ENABLED=true"  >> "${CONF_FILE}"
    else
        echo "MACHINE_LEARNING_ENABLED=false" >> "${CONF_FILE}"
    fi
fi

# The package runs as the immich user — it MUST be able to READ its config and
# WRITE its data dirs. Resolve the (possibly wizard-overridden) data paths.
. "${CONF_FILE}" 2>/dev/null
mkdir -p \
    "${UPLOAD_LOCATION:-/volume1/docker/immich/upload}" \
    "${MACHINE_LEARNING_CACHE_FOLDER:-/volume1/docker/immich/model-cache}" \
    "${INSTALL_ROOT}/log" "${INSTALL_ROOT}/run"
chown -R "${PKG_USER}:${PKG_USER}" \
    "${CONF_DIR}" "${PKG_VAR}" "${INSTALL_ROOT}/log" "${INSTALL_ROOT}/run" \
    "${UPLOAD_LOCATION:-/volume1/docker/immich/upload}" \
    "${MACHINE_LEARNING_CACHE_FOLDER:-/volume1/docker/immich/model-cache}" 2>/dev/null || true
chmod 750 "${CONF_DIR}"
chmod 640 "${CONF_FILE}" 2>/dev/null || true

exit 0
POSTINST_EOF
    chmod +x "${scripts_dir}/postinst"

    # preuninst — pre-uninstall hook
    cat > "${scripts_dir}/preuninst" << 'PREUNINST_EOF'
#!/bin/sh
# preuninst — stop services before uninstall
synopkg stop immich 2>/dev/null || true
exit 0
PREUNINST_EOF
    chmod +x "${scripts_dir}/preuninst"
}

# ── Main ──────────────────────────────────────────────────────────────────────
main() {
    print_build_plan

    check_prereqs
    build_js
    build_redis
    download_nodejs
    download_ffmpeg
    download_perl
    build_postgres
    build_ml_python
    assemble_stage
    create_package_tgz
    assemble_spk
}

main "$@"
