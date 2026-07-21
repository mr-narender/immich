# HEIC/HEVC thumbnail fix for Immich 2.7.5 on Synology

## Problem
iPhone HEIC photos (H.265/HEVC codec) generate inverted/negative thumbnails.
Root cause: `@img/sharp-libvips-linux-x64@1.2.4` bundles libvips with libheif but
HEVC (de265) not compiled in. The `vips-heif.so` plugin loads but fails to decode HEVC.

## Fix
Build custom `libvips.so.42` + `vips-heif.so` with libde265 statically linked.

## Build (on vm104 or any x86_64 Linux Docker host)

```sh
# Clone sources alongside Dockerfile
git clone --depth 1 --branch v1.0.15 https://github.com/strukturag/libde265 libde265
git clone --depth 1 --branch v1.20.1 https://github.com/strukturag/libheif libheif
git clone --depth 1 --branch 8.17.3  https://github.com/libvips/libvips   libvips

# Build image
docker build -t vips-de265-v2 -f Dockerfile .

# Export artifacts
docker run --rm vips-de265-v2 tar -czC /opt/lib \
  libvips.so.42.19.3 libvips-cpp.so.8.17.3 vips-modules-8.17/vips-heif.so \
  $(ls /opt/lib/*.so* | xargs -n1 basename) \
  > vips-deploy.tar.gz
```

## Deploy to NAS

```sh
LIBDIR=/var/packages/immich/target/server/node_modules/.pnpm/@img+sharp-libvips-linux-x64@1.2.4/node_modules/@img/sharp-libvips-linux-x64/lib

# Back up original
cp $LIBDIR/libvips-cpp.so.8.17.3 $LIBDIR/libvips-cpp.so.8.17.3.bak-original

# Extract new libs
tar -xzf vips-deploy.tar.gz -C $LIBDIR

# Create compiled-in module path (libvips built with --prefix=/opt)
mkdir -p /opt/lib/vips-modules-8.17
cp $LIBDIR/vips-heif.so /opt/lib/vips-modules-8.17/
```

## immich.conf

```sh
# /var/packages/immich/target/conf/immich.conf
export UPLOAD_LOCATION=/var/packages/immich/var/upload
export DB_PORT=5434
export VIPS_MODULE_DIR=/opt/lib/vips-modules-8.17
```

Note: `VIPS_MODULE_DIR` is ignored by this libvips build (compiled path = /opt/lib/).
The module loads automatically from `/opt/lib/vips-modules-8.17/` at `vips_init()`.

## After restart: re-enqueue HEIC thumbnails

```sh
/var/packages/immich/target/node/bin/node regen-heic-thumbnails.cjs
```

## Key learnings
- libheif.pc must declare `-lde265` in Libs: or linker prunes de265 from vips-heif.so
  (`sed -i 's|^Libs:.*|& -lde265|' /opt/lib/pkgconfig/libheif.pc`)
- `VIPS_MODULE_DIR` env var only works if compiled into libvips (string present in binary)
- Module loads from compiled-in prefix path at init time, not on demand per file
- Homebrew SSH (OpenSSH 10.3p1) fails to NAS with "No route to host"; use /usr/bin/ssh
