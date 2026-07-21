FROM --platform=linux/amd64 ubuntu:22.04
ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y \
    build-essential cmake pkg-config meson ninja-build python3-pip patchelf \
    libglib2.0-dev libexpat1-dev liblcms2-dev \
    libjpeg-dev libpng-dev libwebp-dev libtiff-dev \
    libfftw3-dev liborc-0.4-dev libexif-dev \
    libgsf-1-dev zlib1g-dev libzstd-dev && \
    pip3 install meson --upgrade && \
    rm -rf /var/lib/apt/lists/*

WORKDIR /build

COPY libde265 libde265
RUN cmake -B de265/build libde265 \
      -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX=/opt \
      -DBUILD_SHARED_LIBS=OFF -DENABLE_SDL=OFF -DENABLE_ENCODER=OFF && \
    cmake --build de265/build -j$(nproc) && cmake --install de265/build

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

COPY libvips libvips
RUN meson setup vips_build libvips \
      --prefix=/opt \
      --libdir=lib \
      --buildtype=release \
      --default-library=shared \
      -Dheif=enabled \
      -Dmagick=disabled \
      -Dopenslide=disabled \
      -Dintrospection=disabled && \
    ninja -C vips_build -j$(nproc) && \
    ninja -C vips_build install

RUN ls -la /opt/lib/libvips* /opt/lib/vips-modules-8.17/
