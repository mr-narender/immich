#!/bin/bash
# Assembles a self-contained Immich SPK for Synology x86_64.
# Run AFTER vm-immich-build.sh has produced server-linux-x64.tar.gz + web-build.tar.gz.
#
# Usage (with defaults):
#   syno/assemble-hybrid.sh
#
# Override any variable:
#   VERSION=3.0.0-1 BASE_SPK=/path/to/base.spk syno/assemble-hybrid.sh
set -euo pipefail

REPO="${REPO:-$(cd "$(dirname "$0")/.." && pwd)}"
VERSION="${VERSION:-3.0.0-1}"
# 2.7.5-1.spk is the full-binary base: postgres, redis, node, geodata bundled.
# 2.7.5-2.spk only has bin/ + perl/ — do NOT use that as the base.
BASE_SPK="${BASE_SPK:-$REPO/immich-x86_64-2.7.5-1.spk}"
OUT_SPK="${OUT_SPK:-$REPO/immich-x86_64-${VERSION}.spk}"
SERVER_TAR="${SERVER_TAR:-/tmp/immich-spk-work/server-linux-x64.tar.gz}"
WEB_TAR="${WEB_TAR:-/tmp/immich-spk-work/web-build.tar.gz}"
SCRIPTS_SRC="$REPO/syno/src/scripts"
W="/tmp/immich-spk-work/hb3"

echo "[0] base=$BASE_SPK"
echo "     out=$OUT_SPK"
test -f "$BASE_SPK"  || { echo "FATAL: BASE_SPK not found: $BASE_SPK";  exit 1; }
test -f "$SERVER_TAR"|| { echo "FATAL: SERVER_TAR not found: $SERVER_TAR"; exit 1; }
test -f "$WEB_TAR"   || { echo "FATAL: WEB_TAR not found: $WEB_TAR";    exit 1; }

echo "[1] explode base spk"
rm -rf "$W/inj"; mkdir -p "$W/inj"
COPYFILE_DISABLE=1 /usr/bin/tar xf "$BASE_SPK" -C "$W/inj"

echo "[2] explode package.tgz into stage"
rm -rf "$W/stage"; mkdir -p "$W/stage"
COPYFILE_DISABLE=1 /usr/bin/tar xzf "$W/inj/package.tgz" -C "$W/stage"

cd "$W/stage"
echo "[2a] base stage contents:"
find . -maxdepth 1 -type d | sort

echo "[3] remove stale version-specific trees (keep postgres/redis/node/geodata/bin/perl)"
rm -rf ./server ./web ./machine-learning ./python ./toolchain

echo "[3a] inject server (linux-x64, built on vm105 — correct-platform natives)"
mkdir -p ./server
COPYFILE_DISABLE=1 /usr/bin/tar xzf "$SERVER_TAR" -C ./server

echo "[3b] inject web to www/ (server reads \${IMMICH_BUILD_DATA}/www/ per config.repository.js)"
rm -rf ./www
mkdir -p ./www
# web-build.tar.gz packs -C web/ build → top-level is build/; strip it
COPYFILE_DISABLE=1 /usr/bin/tar xzf "$WEB_TAR" --strip-components=1 -C ./www

echo "[4] env.default: ensure DB_VECTOR_EXTENSION=pgvector"
grep -q '^DB_VECTOR_EXTENSION=' ./env.default 2>/dev/null || \
  echo 'DB_VECTOR_EXTENSION=pgvector' >> ./env.default

echo "[5] bin wrappers: inject IMMICH_BUILD_DATA + DB_VECTOR_EXTENSION before exec"
for w in ./bin/immich-server ./bin/immich-microservices; do
  [ -f "$w" ] || continue
  # IMMICH_BUILD_DATA → geodata/ and www/ resolved as ${INSTALL_ROOT}/geodata/ and ${INSTALL_ROOT}/www/
  grep -q 'IMMICH_BUILD_DATA' "$w" || \
    sed -i.bak 's|^exec |export IMMICH_BUILD_DATA="${INSTALL_ROOT}"\nexec |' "$w"
  # DB_VECTOR_EXTENSION → pgvector (not pgvecto.rs; v3.0 dropped pgvecto.rs)
  grep -q 'DB_VECTOR_EXTENSION' "$w" || \
    sed -i.bak 's|^exec |export DB_VECTOR_EXTENSION="${DB_VECTOR_EXTENSION:-pgvector}"\nexec |' "$w"
  rm -f "$w.bak"
done

echo "[5a] bin/immich-server injected lines:"
grep -E 'IMMICH_BUILD_DATA|DB_VECTOR_EXTENSION|^exec' ./bin/immich-server

echo "[6] repack package.tgz (COPYFILE_DISABLE=1 blocks macOS ._* resource fork files)"
COPYFILE_DISABLE=1 /usr/bin/tar czf "$W/inj/package.tgz" -C "$W/stage" .

echo "[7] metadata overlays"
cp "$REPO/syno/INFO" "$W/inj/INFO"
cp "$SCRIPTS_SRC/start-stop-status" "$W/inj/scripts/start-stop-status"
cp "$SCRIPTS_SRC/preinst"           "$W/inj/scripts/preinst"
chmod +x "$W/inj/scripts/"*

# preupgrade/postupgrade: required by synopkg for upgrades (no-op is sufficient)
printf '#!/bin/sh\nexit 0\n' > "$W/inj/scripts/preupgrade"
printf '#!/bin/sh\nexit 0\n' > "$W/inj/scripts/postupgrade"
chmod +x "$W/inj/scripts/preupgrade" "$W/inj/scripts/postupgrade"

echo "[8] assemble outer spk"
cd "$W/inj"
EXTRA=""
[ -d conf ]   && EXTRA="$EXTRA conf"
[ -d wizard ] && EXTRA="$EXTRA wizard"
# shellcheck disable=SC2086
COPYFILE_DISABLE=1 /usr/bin/tar cf "$OUT_SPK" INFO package.tgz scripts $EXTRA

SIZE=$(stat -f%z "$OUT_SPK" 2>/dev/null || stat -c%s "$OUT_SPK")
echo "ASSEMBLE_DONE ${SIZE} bytes -> $OUT_SPK"
