FROM --platform=linux/amd64 ubuntu:22.04
ENV DEBIAN_FRONTEND=noninteractive

# TARGET = where immich-spk installs on the NAS; libvips compiles this path in
# so vips-heif.so is found at vips_init() without any env override.
ENV INSTALL_PREFIX=/var/packages/immich/target

RUN apt-get update && apt-get install -y \
    build-essential cmake pkg-config meson ninja-build python3-pip patchelf \
    libglib2.0-dev libexpat1-dev liblcms2-dev \
    libjpeg-dev libpng-dev libwebp-dev libtiff-dev \
    libfftw3-dev liborc-0.4-dev libexif-dev \
    libgsf-1-dev zlib1g-dev libzstd-dev && \
    pip3 install meson --upgrade && \
    rm -rf /var/lib/apt/lists/*

WORKDIR /build

# libde265 v1.0.15 — HEVC software decoder (static, embedded in libheif)
COPY libde265 libde265
RUN cmake -B de265/build libde265 \
      -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX=/opt \
      -DBUILD_SHARED_LIBS=OFF -DENABLE_SDL=OFF -DENABLE_ENCODER=OFF && \
    cmake --build de265/build -j$(nproc) && cmake --install de265/build

# libheif v1.20.1 — security limit raised to 1024 references (vs 16 in 1.12.0)
ENV PKG_CONFIG_PATH=/opt/lib/pkgconfig
COPY libheif libheif
RUN cmake -B heif/build libheif \
      -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX=/opt \
      -DCMAKE_PREFIX_PATH=/opt \
      -DBUILD_SHARED_LIBS=OFF \
      -DWITH_LIBDE265=ON -DWITH_LIBDE265_PLUGIN=OFF \
      -DWITH_X265=OFF -DWITH_AOM_DECODER=OFF -DWITH_AOM_ENCODER=OFF \
      -DENABLE_PLUGIN_LOADING=OFF \
      -DBUILD_TESTING=OFF -DBUILD_EXAMPLES=OFF && \
    cmake --build heif/build -j$(nproc) && cmake --install heif/build

# Patch libheif.pc so libvips links libde265.a when building vips-heif.so
RUN sed -i 's|^Libs:.*|& -lde265|' /opt/lib/pkgconfig/libheif.pc && \
    grep 'Libs:' /opt/lib/pkgconfig/libheif.pc

# libvips v8.18.3 — must match @img/sharp-libvips-linux-x64@1.3.2 (libvips-cpp.so.8.18.3)
# prefix = NAS install root so vips-modules-8.18/ is found at runtime without VIPS_MODULE_DIR
COPY libvips libvips
RUN meson setup vips_build libvips \
      --prefix="${INSTALL_PREFIX}" \
      --libdir=lib \
      --buildtype=release \
      --default-library=shared \
      -Dheif=enabled \
      -Dmagick=disabled \
      -Dopenslide=disabled \
      -Dintrospection=disabled && \
    ninja -C vips_build -j$(nproc) && \
    DESTDIR=/output ninja -C vips_build install

# Verify outputs
RUN ls -la /output${INSTALL_PREFIX}/lib/libvips* \
           /output${INSTALL_PREFIX}/lib/vips-modules-8.18/
