#!/bin/bash
# Runs ON the x86_64 build host (set PG_BUILD_HOST). Builds postgres 14 + pgvector 0.8.0 inside a
# glibc-2.17 manylinux2014 container so binaries run on any DSM (>=2.17).
# Sources are downloaded HERE on the host (Ubuntu 24.04, modern TLS) and
# mounted into the container — manylinux2014's centos7 curl can't do GitHub TLS.
set -euo pipefail
OUT=/tmp/pgout;  rm -rf "$OUT";  mkdir -p "$OUT"
SRC=/tmp/pgsrc;  rm -rf "$SRC";  mkdir -p "$SRC"

PGV=14.13
echo "=== host download (modern curl) ==="
cd "$SRC"
curl -fsSLO "https://ftp.postgresql.org/pub/source/v${PGV}/postgresql-${PGV}.tar.gz"
curl -fsSL  "https://github.com/pgvector/pgvector/archive/refs/tags/v0.8.0.tar.gz" -o pgvector-0.8.0.tar.gz
ls -la "$SRC"
# Fail early if either source is missing/empty
test -s "postgresql-${PGV}.tar.gz" || { echo "POSTGRES_SRC_MISSING"; exit 1; }
test -s "pgvector-0.8.0.tar.gz"    || { echo "PGVECTOR_SRC_MISSING"; exit 1; }

# Inner build script (runs in the container, OFFLINE — sources come from /src)
cat > /tmp/pginner.sh <<'INNER'
#!/bin/bash
set -euo pipefail
echo "=== compiler ==="; gcc --version | head -1
yum install -y -q libuuid-devel >/dev/null 2>&1 || true   # uuid/uuid.h for contrib/uuid-ossp
cd /tmp
tar xzf /src/postgresql-14.13.tar.gz
cd postgresql-14.13
./configure --prefix=/var/packages/immich/target/postgres \
  --with-uuid=e2fs \
  --without-icu --without-readline --without-zlib --without-openssl \
  --without-ldap --without-gssapi --without-libxml --without-lz4 --without-zstd \
  CFLAGS="-O2" > /tmp/conf.log 2>&1
make -j"$(nproc)" > /tmp/make.log 2>&1
make install DESTDIR=/tmp/stage > /tmp/install.log 2>&1
# Contrib extensions immich 2.7.5 requires (cube must precede earthdistance).
for ext in cube earthdistance pg_trgm unaccent uuid-ossp; do
  make -C "contrib/${ext}"                          >> /tmp/contrib.log 2>&1
  make -C "contrib/${ext}" install DESTDIR=/tmp/stage >> /tmp/contrib.log 2>&1
done

cd /tmp
tar xzf /src/pgvector-0.8.0.tar.gz
cd pgvector-0.8.0
PGC=/tmp/stage/var/packages/immich/target/postgres/bin/pg_config
make OPTFLAGS="" PG_CONFIG="$PGC" > /tmp/vec.log 2>&1
# NO DESTDIR here: this pg_config is relocatable and already reports the staged
# prefix, so DESTDIR would double-prepend (/tmp/stage/tmp/stage/...). postgres
# install (above) keeps DESTDIR because its pg_config reports the baked prefix.
make install OPTFLAGS="" PG_CONFIG="$PGC" >> /tmp/vec.log 2>&1

P=/tmp/stage/var/packages/immich/target/postgres
# HARD GATE: pgvector MUST be present or the whole build fails (no silent ship).
# Vanilla source build uses simple prefix layout: $P/lib + $P/share/extension
# (NOT Debian's nested lib/postgresql/14/lib + share/postgresql/14).
test -f "$P/lib/vector.so"                  || { echo "VECTOR_SO_MISSING";      tail -20 /tmp/vec.log; exit 1; }
test -f "$P/share/extension/vector.control" || { echo "VECTOR_CONTROL_MISSING"; exit 1; }
# All immich-required contrib extensions must be present
for ctl in cube earthdistance pg_trgm unaccent uuid-ossp; do
  test -f "$P/share/extension/${ctl}.control" || { echo "EXT_MISSING_${ctl}"; tail -25 /tmp/contrib.log; exit 1; }
done
echo "=== extensions ==="; ls "$P/share/extension/" | grep -E 'vector|cube|earthdistance|pg_trgm|unaccent|uuid' | tr '\n' ' '; echo

echo "=== file ==="; file "$P/bin/postgres"
echo "=== NEEDED ==="; readelf -d "$P/bin/postgres" | grep NEEDED || true
echo "=== maxGLIBC ==="; readelf -V "$P/bin/postgres" 2>/dev/null | grep -o "GLIBC_[0-9.]*" | sort -V | tail -1
echo "=== vector ==="; find "$P" -name vector.so; find "$P" -name vector.control
cd /tmp/stage/var/packages/immich/target
tar czf /out/postgres-x86_64.tar.gz postgres
echo "INNER_DONE"
INNER
chmod +x /tmp/pginner.sh

docker pull -q quay.io/pypa/manylinux2014_x86_64 >/dev/null
docker run --rm -v "$OUT":/out -v "$SRC":/src:ro -v /tmp/pginner.sh:/pginner.sh:ro \
    quay.io/pypa/manylinux2014_x86_64 bash /pginner.sh

echo "OUTER_DONE size=$(stat -c%s "$OUT/postgres-x86_64.tar.gz" 2>/dev/null || echo 0)"
