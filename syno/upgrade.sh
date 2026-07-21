#!/bin/bash
# syno/upgrade.sh — full Immich upgrade on Synology NAS, end-to-end.
#
# Usage:
#   bash syno/upgrade.sh                  # auto-detect latest GitHub release
#   VERSION=3.0.2 bash syno/upgrade.sh    # pin specific version
#
# Prerequisites (all must be reachable from Mac):
#   vm105 — 192.168.2.105 (immich-build, ssh narender@)
#   NAS   — 192.168.2.2   (ssh narender@, sudo available)
#   ~/dev/tools/immich/immich-x86_64-2.7.5-1.spk — base SPK for binary deps
#
# What this script does:
#   1. Detect target version (arg or GitHub latest)
#   2. Skip if NAS already on that version
#   3. Clone source + build on vm105 (server + web tarballs)
#   4. SCP tarballs back to Mac
#   5. Update syno/INFO (version + changelog)
#   6. Run assemble-hybrid.sh → immich-x86_64-<VERSION>-1.spk
#   7. SCP SPK to NAS, install via synopkg, verify
#   8. Cleanup temp files; commit INFO change
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
SSH="/usr/bin/ssh -o BatchMode=yes -o ConnectTimeout=15"
VM105="narender@192.168.2.105"
NAS="narender@192.168.2.2"
WORK="/tmp/immich-spk-work"
BUILD_SCRIPT="/tmp/vm-immich-build.sh"

# ── 1. Resolve target version ────────────────────────────────────────────────
if [ -z "${VERSION:-}" ]; then
  echo "[1] auto-detecting latest GitHub release..."
  VERSION=$(python3 -c "
import urllib.request, json, ssl
ctx = ssl.create_default_context()
req = urllib.request.Request(
  'https://api.github.com/repos/immich-app/immich/releases/latest',
  headers={'User-Agent': 'immich-syno-upgrade'}
)
data = json.loads(urllib.request.urlopen(req, context=ctx).read())
print(data['tag_name'].lstrip('v'))
")
  echo "[1] latest = v${VERSION}"
else
  echo "[1] target version = v${VERSION} (from env)"
fi

SPK_VERSION="${VERSION}-1"
OUT_SPK="${REPO}/immich-x86_64-${SPK_VERSION}.spk"

# ── 2. Skip if already on this version ──────────────────────────────────────
echo "[2] checking NAS current version..."
NAS_VERSION=$(${SSH} "${NAS}" '
  grep "v[0-9]" /var/packages/immich/target/log/server.log 2>/dev/null \
    | grep -oE "v[0-9]+\.[0-9]+\.[0-9]+" | tail -1 || echo "unknown"
')
echo "[2] NAS running: ${NAS_VERSION}"
if [ "${NAS_VERSION}" = "v${VERSION}" ]; then
  echo "[2] Already on v${VERSION} — nothing to do."
  exit 0
fi

# ── 3. Clone source + build on vm105 ────────────────────────────────────────
echo "[3] cloning v${VERSION} on vm105 and building..."
${SSH} "${VM105}" "
  set -e
  rm -rf /tmp/immich-src /tmp/immich-out
  git clone https://github.com/immich-app/immich.git \
    --branch v${VERSION} --depth 1 /tmp/immich-src 2>&1 | tail -3
  echo 'CLONE_DONE'
"

${SSH} "${VM105}" 'cat > '"${BUILD_SCRIPT}" < "${REPO}/syno/vm-immich-build.sh"
${SSH} "${VM105}" "chmod +x ${BUILD_SCRIPT} && ${BUILD_SCRIPT}"
echo "[3] build done"

# ── 4. SCP tarballs to Mac ───────────────────────────────────────────────────
echo "[4] downloading build artifacts..."
mkdir -p "${WORK}"
${SSH} "${VM105}" 'cat /tmp/immich-out/server-linux-x64.tar.gz' > "${WORK}/server-linux-x64.tar.gz"
${SSH} "${VM105}" 'cat /tmp/immich-out/web-build.tar.gz'        > "${WORK}/web-build.tar.gz"
echo "[4] server=$(du -sh "${WORK}/server-linux-x64.tar.gz" | cut -f1) web=$(du -sh "${WORK}/web-build.tar.gz" | cut -f1)"

# ── 5. Patch syno/INFO ───────────────────────────────────────────────────────
echo "[5] patching syno/INFO..."
CHANGELOG=$(python3 -c "
import urllib.request, json, ssl
ctx = ssl.create_default_context()
req = urllib.request.Request(
  'https://api.github.com/repos/immich-app/immich/releases/tags/v${VERSION}',
  headers={'User-Agent': 'immich-syno-upgrade'}
)
data = json.loads(urllib.request.urlopen(req, context=ctx).read())
body = data.get('body', '')
# First non-empty line after the title
lines = [l.strip() for l in body.splitlines() if l.strip() and not l.startswith('#')]
print(lines[0][:120] if lines else 'Immich v${VERSION}')
" 2>/dev/null || echo "Immich v${VERSION}")

# Update version and changelog in INFO (in-place, macOS + Linux sed compatible)
python3 - <<PYEOF
import re, pathlib
info = pathlib.Path('${REPO}/syno/INFO')
text = info.read_text()
text = re.sub(r'^version="[^"]*"', 'version="${SPK_VERSION}"', text, flags=re.M)
text = re.sub(r'^changelog="[^"]*"', 'changelog="Immich v${VERSION} — ${CHANGELOG}"', text, flags=re.M)
info.write_text(text)
print('INFO patched:', text[:200])
PYEOF

# ── 6. Assemble SPK ──────────────────────────────────────────────────────────
echo "[6] assembling SPK..."
VERSION="${SPK_VERSION}" COPYFILE_DISABLE=1 bash "${REPO}/syno/assemble-hybrid.sh"
echo "[6] SPK: $(du -sh "${OUT_SPK}" | cut -f1) → ${OUT_SPK}"

# ── 7. Install on NAS ────────────────────────────────────────────────────────
echo "[7] uploading SPK to NAS..."
NAS_SPK="/tmp/immich-x86_64-${SPK_VERSION}.spk"
${SSH} "${NAS}" "cat > ${NAS_SPK}" < "${OUT_SPK}"
echo "[7] installing..."
RESULT=$(${SSH} "${NAS}" "sudo /usr/syno/bin/synopkg install ${NAS_SPK} 2>&1")
echo "[7] ${RESULT}" | python3 -c "
import sys, json
raw = sys.stdin.read()
try:
  d = json.loads(raw.split('[7] ', 1)[-1])
  r = d.get('results', [{}])[0]
  print(f'  action={r.get(\"action\")} success={r.get(\"success\")} version={r.get(\"version\")} stage={r.get(\"stage\")}')
except Exception:
  print(raw[:300])
"

echo "[7] verifying port 2283..."
sleep 15
LISTENING=$(${SSH} "${NAS}" 'netstat -tln 2>/dev/null | grep -c ":2283 " || echo 0')
[ "${LISTENING}" -ge 1 ] || { echo "ERROR: port 2283 not listening after install"; exit 1; }
echo "[7] port 2283 UP ✓"

echo "[7] cleanup NAS temp SPK..."
${SSH} "${NAS}" "rm -f ${NAS_SPK}"

# ── 8. Commit INFO change ────────────────────────────────────────────────────
echo "[8] committing syno/INFO..."
cd "${REPO}"
git add syno/INFO
git commit -F - <<MSGEOF
chore(syno): bump version to ${SPK_VERSION}

Immich v${VERSION} — ${CHANGELOG}
Built server+web on vm105 (192.168.2.105, immich-build).

Co-Authored-By: Claude Sonnet 4.6 <noreply@anthropic.com>
MSGEOF

echo ""
echo "============================================================"
echo " Immich upgraded to v${VERSION} on NAS (192.168.2.2)"
echo " SPK: ${OUT_SPK}"
echo "============================================================"
