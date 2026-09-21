#!/usr/bin/env bash
# deploy-heif-3.2.2.sh — Build libvips+libheif via Docker, then deploy to the
# running NAS Immich 3.2.2.
#
# Usage:
#   NAS=narender@192.168.2.2 bash deploy-heif-3.2.2.sh
set -euo pipefail

NAS="${NAS:-narender@192.168.2.2}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_PREFIX="/var/packages/immich/target"
SHARP_LIBVIPS_DIR="${INSTALL_PREFIX}/server/node_modules/.pnpm/@img+sharp-libvips-linux-x64@1.3.2/node_modules/@img/sharp-libvips-linux-x64/lib"
VIPS_MODULE_DIR="${INSTALL_PREFIX}/lib/vips-modules-8.18"
OUT="${SCRIPT_DIR}/out-3.2.2"

echo "=== Step 1: Clone source repos (if missing) ==="
for spec in \
    "libde265|https://github.com/strukturag/libde265.git|v1.0.15" \
    "libheif|https://github.com/strukturag/libheif.git|v1.20.1" \
    "libvips|https://github.com/libvips/libvips.git|v8.18.3"; do
    name="${spec%%|*}"; rest="${spec#*|}"; url="${rest%%|*}"; tag="${rest##*|}"
    if [ ! -d "${SCRIPT_DIR}/${name}" ]; then
        echo "  Cloning ${name} ${tag}..."
        git clone --depth 1 --branch "${tag}" "${url}" "${SCRIPT_DIR}/${name}"
    else
        echo "  ${name} already present"
    fi
done

echo "=== Step 2: Docker build (linux/amd64, ~10-15 min first run) ==="
docker build --platform linux/amd64 --tag immich-vips-heif:3.2.2 "${SCRIPT_DIR}"

echo "=== Step 3: Extract libs ==="
rm -rf "${OUT}"; mkdir -p "${OUT}"
CID="$(docker create immich-vips-heif:3.2.2)"
docker cp "${CID}:/output${INSTALL_PREFIX}/lib/libvips-cpp.so.8.18.3" "${OUT}/libvips-cpp.so.8.18.3"
docker cp "${CID}:/output${INSTALL_PREFIX}/lib/vips-modules-8.18/vips-heif.so" "${OUT}/vips-heif.so"
docker rm "${CID}" > /dev/null
echo "  libvips-cpp.so.8.18.3: $(file "${OUT}/libvips-cpp.so.8.18.3" | grep -o 'ELF.*')"
echo "  vips-heif.so:          $(file "${OUT}/vips-heif.so"           | grep -o 'ELF.*')"

echo "=== Step 4: Copy libs to NAS ==="
scp "${OUT}/libvips-cpp.so.8.18.3" "${NAS}:/tmp/libvips-cpp.so.8.18.3"
scp "${OUT}/vips-heif.so"          "${NAS}:/tmp/vips-heif.so"

echo "=== Step 5: Deploy on NAS + restart Immich ==="
ssh "${NAS}" "sudo bash -s" << REMOTE_EOF
set -euo pipefail
SHARP_LIBVIPS_DIR="${SHARP_LIBVIPS_DIR}"
VIPS_MODULE_DIR="${VIPS_MODULE_DIR}"

if [ ! -f "\${SHARP_LIBVIPS_DIR}/libvips-cpp.so.8.18.3.orig" ]; then
    cp "\${SHARP_LIBVIPS_DIR}/libvips-cpp.so.8.18.3" "\${SHARP_LIBVIPS_DIR}/libvips-cpp.so.8.18.3.orig"
    echo "  Backed up original libvips-cpp.so.8.18.3"
fi

cp /tmp/libvips-cpp.so.8.18.3 "\${SHARP_LIBVIPS_DIR}/libvips-cpp.so.8.18.3"
echo "  Deployed libvips-cpp.so.8.18.3"

mkdir -p "\${VIPS_MODULE_DIR}"
cp /tmp/vips-heif.so "\${VIPS_MODULE_DIR}/vips-heif.so"
echo "  Deployed vips-heif.so to \${VIPS_MODULE_DIR}"

synopkg restart immich
echo "  Immich restarted"
REMOTE_EOF

echo "=== Step 6: Re-enqueue all HEIC assets ==="
scp "${SCRIPT_DIR}/regen-heic-thumbnails.cjs" "${NAS}:/tmp/regen-heic-thumbnails.cjs"
ssh "${NAS}" "sudo /var/packages/immich/target/node/bin/node /tmp/regen-heic-thumbnails.cjs"

echo ""
echo "Done. HEIC thumbnails will regenerate via the job queue."
