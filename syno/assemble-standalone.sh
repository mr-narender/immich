#!/bin/bash
# syno/assemble-standalone.sh — Build Synology SPK from scratch (no base SPK).
set -euo pipefail

REPO="${REPO:-$(cd "$(dirname "$0")/.." && pwd)}"
VERSION="${VERSION:-3.0.1-1}"
ARCH="${ARCH:-x86_64}"
OUT_SPK="${OUT_SPK:-$REPO/immich-${ARCH}-${VERSION}.spk}"
SERVER_TAR="${SERVER_TAR:?SERVER_TAR required}"
WEB_TAR="${WEB_TAR:?WEB_TAR required}"
POSTGRES_TAR="${POSTGRES_TAR:?POSTGRES_TAR required}"
REDIS_TAR="${REDIS_TAR:?REDIS_TAR required}"
NODE_TAR="${NODE_TAR:?NODE_TAR required}"
GEODATA_DIR="${GEODATA_DIR:?GEODATA_DIR required}"
SCRIPTS_SRC="$REPO/syno/src/scripts"
W="/tmp/immich-spk-standalone"

# pre-flight
test -f "$SERVER_TAR"   || { echo "FATAL: SERVER_TAR not found: $SERVER_TAR";   exit 1; }
test -f "$WEB_TAR"      || { echo "FATAL: WEB_TAR not found: $WEB_TAR";         exit 1; }
test -f "$POSTGRES_TAR" || { echo "FATAL: POSTGRES_TAR not found: $POSTGRES_TAR"; exit 1; }
test -f "$REDIS_TAR"    || { echo "FATAL: REDIS_TAR not found: $REDIS_TAR";     exit 1; }
test -f "$NODE_TAR"     || { echo "FATAL: NODE_TAR not found: $NODE_TAR";       exit 1; }
test -d "$GEODATA_DIR"  || { echo "FATAL: GEODATA_DIR not found: $GEODATA_DIR"; exit 1; }

echo "[0] standalone build arch=$ARCH version=$VERSION"
echo "    out=$OUT_SPK"

# [1] fresh stage
rm -rf "$W"; mkdir -p "$W/stage"
cd "$W/stage"

# [2] server
echo "[2] inject server"
mkdir -p server
tar xzf "$SERVER_TAR" -C server

# [3] web → www/
echo "[3] inject web"
mkdir -p www
tar xzf "$WEB_TAR" --strip-components=1 -C www

# [4] postgres
echo "[4] inject postgres"
mkdir -p postgres
tar xzf "$POSTGRES_TAR" -C postgres

# [5] redis
echo "[5] inject redis"
mkdir -p redis
tar xzf "$REDIS_TAR" -C redis

# [6] node runtime
echo "[6] inject node"
mkdir -p node
tar xJf "$NODE_TAR" -C node --strip-components=1 2>/dev/null || \
  tar xzf "$NODE_TAR" -C node --strip-components=1

# [7] geodata
echo "[7] inject geodata"
cp -r "$GEODATA_DIR" ./geodata

# [8] conf + env.default
echo "[8] overlays"
mkdir -p conf
[ -d "$REPO/syno/src/conf" ] && cp -r "$REPO/syno/src/conf/." ./conf/
[ -f "$REPO/syno/src/immich.env.default" ] && cp "$REPO/syno/src/immich.env.default" ./env.default

# [9] bin/ wrappers (exact content — do not edit)
echo "[9] bin wrappers"
mkdir -p bin
cat > bin/immich-server << 'BINEOF'
#!/bin/sh
INSTALL_ROOT="/var/packages/immich/target"
NODE="${INSTALL_ROOT}/node/bin/node"
SERVER_DIST="${INSTALL_ROOT}/server/dist"
if [ -f "${INSTALL_ROOT}/conf/immich.conf" ]; then . "${INSTALL_ROOT}/conf/immich.conf"; fi
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
export PATH="${INSTALL_ROOT}/node/bin:${PATH}"
export NODE_MODULES="${INSTALL_ROOT}/server/node_modules"
export DB_VECTOR_EXTENSION="${DB_VECTOR_EXTENSION:-pgvector}"
export IMMICH_BUILD_DATA="${IMMICH_BUILD_DATA:-/var/packages/immich/target}"
exec "${NODE}" "${SERVER_DIST}/main" "$@"
BINEOF

cat > bin/immich-microservices << 'BINEOF'
#!/bin/sh
INSTALL_ROOT="/var/packages/immich/target"
NODE="${INSTALL_ROOT}/node/bin/node"
SERVER_DIST="${INSTALL_ROOT}/server/dist"
if [ -f "${INSTALL_ROOT}/conf/immich.conf" ]; then . "${INSTALL_ROOT}/conf/immich.conf"; fi
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
export PATH="${INSTALL_ROOT}/node/bin:${PATH}"
export DB_VECTOR_EXTENSION="${DB_VECTOR_EXTENSION:-pgvector}"
export IMMICH_BUILD_DATA="${IMMICH_BUILD_DATA:-/var/packages/immich/target}"
exec "${NODE}" "${SERVER_DIST}/main" "$@"
BINEOF

chmod +x bin/immich-server bin/immich-microservices

# [10] ensure DB_VECTOR_EXTENSION in env.default
grep -q '^DB_VECTOR_EXTENSION=' ./env.default 2>/dev/null || \
  echo 'DB_VECTOR_EXTENSION=pgvector' >> ./env.default

# [11] pack package.tgz
echo "[11] pack package.tgz"
mkdir -p "$W/outer/scripts"
COPYFILE_DISABLE=1 tar czf "$W/outer/package.tgz" -C "$W/stage" .

# [12] metadata overlays
echo "[12] metadata"
cp "$REPO/syno/INFO" "$W/outer/INFO"
cp "$SCRIPTS_SRC/start-stop-status" "$W/outer/scripts/start-stop-status"
cp "$SCRIPTS_SRC/preinst"           "$W/outer/scripts/preinst"
chmod +x "$W/outer/scripts/"*
printf '#!/bin/sh\nexit 0\n' > "$W/outer/scripts/preupgrade"
printf '#!/bin/sh\nexit 0\n' > "$W/outer/scripts/postupgrade"
chmod +x "$W/outer/scripts/preupgrade" "$W/outer/scripts/postupgrade"

# [13] outer SPK
echo "[13] assemble outer SPK"
cd "$W/outer"
EXTRA=""
[ -d conf ]   && EXTRA="$EXTRA conf"
[ -d wizard ] && EXTRA="$EXTRA wizard"
COPYFILE_DISABLE=1 tar cf "$OUT_SPK" INFO package.tgz scripts $EXTRA

SIZE=$(stat -f%z "$OUT_SPK" 2>/dev/null || stat -c%s "$OUT_SPK")
echo "STANDALONE_DONE ${SIZE} bytes -> $OUT_SPK"
