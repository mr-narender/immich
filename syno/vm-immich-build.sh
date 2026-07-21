#!/bin/bash
# Runs ON the x86_64 build host (set PG_BUILD_HOST). Builds immich server PROD deps + dist for linux-x64
# (correct-platform native binaries: sharp, etc.), prunes, tars for injection.
# Source expected at /tmp/immich-src (scp'd by the caller).
set -euo pipefail
SRC=/tmp/immich-src
OUT=/tmp/immich-out; rm -rf "$OUT"; mkdir -p "$OUT"
NODEDIR=/tmp/node

# --- Node 24 linux-x64 (official; also the runtime we bundle) ---
if [ ! -x "${NODEDIR}/bin/node" ]; then
  rm -rf "$NODEDIR"; mkdir -p "$NODEDIR"
  curl -fsSL https://nodejs.org/dist/v24.15.0/node-v24.15.0-linux-x64.tar.xz | tar xJ -C "$NODEDIR" --strip-components=1
fi
export PATH="${NODEDIR}/bin:$PATH"
node --version
# pnpm version comes from the repo's package.json "packageManager" (corepack auto-activates)
corepack enable >/dev/null 2>&1 || true
cd "$SRC"
corepack prepare --activate >/dev/null 2>&1 || true
pnpm --version

# --- build immich (workspace) ---
cd "$SRC"
pnpm install --frozen-lockfile > /tmp/immich-build.log 2>&1
pnpm --filter @immich/sdk build        >> /tmp/immich-build.log 2>&1
pnpm --filter @immich/plugin-sdk build >> /tmp/immich-build.log 2>&1 || true
pnpm --filter immich build             >> /tmp/immich-build.log 2>&1
pnpm --filter immich-web build         >> /tmp/immich-build.log 2>&1

# --- prod deploy: linux-x64 node_modules + dist, workspace deps inlined ---
rm -rf /tmp/server-deploy
pnpm --filter immich deploy --prod --legacy /tmp/server-deploy >> /tmp/immich-build.log 2>&1 \
  || pnpm --filter immich deploy --prod /tmp/server-deploy >> /tmp/immich-build.log 2>&1
test -f /tmp/server-deploy/dist/main.js || test -f /tmp/server-deploy/dist/main || { echo "DIST_MISSING"; tail -30 /tmp/immich-build.log; exit 1; }

SIZE_BEFORE=$(du -sm /tmp/server-deploy/node_modules | cut -f1)

# --- prune (linux-x64 only natives + strip cruft) ---
cd /tmp/server-deploy/node_modules
# Remove non-linux-x64 native prebuilds only (safe — platform binaries).
find . -type d \( -name '*darwin*' -o -name '*win32*' -o -name '*linuxmusl*' \
   -o -name '*linux-arm' -o -name '*linux-arm64' -o -name '*linux-s390x' \
   -o -name '*linux-ppc64*' -o -name '*android*' -o -name '*freebsd*' \) \
   -exec rm -rf {} + 2>/dev/null || true
# Safe FILE-level strip ONLY. Do NOT delete dirs named doc/docs/test/example —
# many packages keep CODE there (e.g. yaml/dist/doc/directives.js); deleting them
# broke the runtime. Source maps + .github are safe.
find . -type f \( -name '*.map' -o -name '*.markdown' \) -delete 2>/dev/null || true
find . -type d -name '.github' -exec rm -rf {} + 2>/dev/null || true
SIZE_AFTER=$(du -sm /tmp/server-deploy/node_modules | cut -f1)

# --- HARD GATE: sharp must load on linux-x64 (catches over-prune / wrong platform) ---
cd /tmp/server-deploy
node -e "require('sharp'); console.log('SHARP_OK', require('sharp/package.json').version)" \
  || { echo "SHARP_LOAD_FAIL"; exit 1; }

# --- package the server tree (dist + pruned node_modules + manifests) ---
tar czf "$OUT/server-linux-x64.tar.gz" -C /tmp/server-deploy .
# also web build (static, portable, but rebuild here for consistency)
tar czf "$OUT/web-build.tar.gz" -C "$SRC/web" build 2>/dev/null || \
tar czf "$OUT/web-build.tar.gz" -C "$SRC/web" dist 2>/dev/null || echo "WEB_NOTE: check web output dir"
echo "SERVER_DONE before=${SIZE_BEFORE}MB after=${SIZE_AFTER}MB tar=$(stat -c%s "$OUT/server-linux-x64.tar.gz")"
