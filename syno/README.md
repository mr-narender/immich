# Immich Synology SPK

Native Synology NAS package for Immich — no Docker required on the NAS.

| Field | Value |
|-------|-------|
| Architecture | x86_64 |
| DSM minimum | 7.2-64561 |
| Immich port | 2283 |
| Config UI port | 2284 |

---

## Upgrade to a new release

Single command, fully automated:

```bash
# Auto-detect latest GitHub release and upgrade
bash syno/upgrade.sh

# Pin a specific version
VERSION=3.0.2 bash syno/upgrade.sh
```

The script detects the current NAS version, **skips if already up to date**, and
otherwise runs the full build→assemble→install pipeline unattended.

### Prerequisites

| Host | Address | Requirement |
|------|---------|-------------|
| vm105 | `narender@192.168.2.105` | ssh key auth; Docker; git; Node 24 |
| NAS | `narender@192.168.2.2` | ssh key auth; sudo |
| Base SPK | `immich-x86_64-2.7.5-1.spk` in repo root | Binary deps (postgres/redis/node/geodata) |

### What upgrade.sh does

| Step | Action |
|------|--------|
| 1 | GitHub API → detect latest version (or use `$VERSION`) |
| 2 | Skip if NAS already on that version |
| 3 | `git clone v<VERSION> --depth 1` on vm105 → `vm-immich-build.sh` |
| 4 | Download server + web tarballs Mac ← vm105 |
| 5 | Patch `syno/INFO` (version + first line of release notes) |
| 6 | `assemble-hybrid.sh` → `immich-x86_64-<VERSION>-1.spk` |
| 7 | Upload SPK → NAS `synopkg install` → verify port 2283 → cleanup |
| 8 | `git commit` INFO bump |

---

## Machine Learning

ML runs as a Docker container on **vm105** (192.168.2.105). Never use vm104.

> **vm104 (`192.168.2.104`) = CI runner only.** Its Proxmox CPU type is `kvm64`
> (x86-64-v1, no SSE4.2). The ML image's NumPy requires X86_V2 and crashes on vm104.
> vm105 has `cpu=host` (i5-12400F: SSE4.2/AVX/AVX2).

### Update ML container after a server upgrade

```bash
NEW_VERSION=3.0.1
ssh narender@192.168.2.105 "
  docker stop immich-ml && docker rm immich-ml
  docker run -d \
    --name immich-ml \
    -p 3003:3003 \
    -v immich-ml-cache:/cache \
    -e MACHINE_LEARNING_CACHE_FOLDER=/cache \
    --restart unless-stopped \
    ghcr.io/immich-app/immich-machine-learning:v\${NEW_VERSION}
"
```

### Change ML URL

Via Config UI at `http://192.168.2.2:2284`, or directly:

```bash
ssh narender@192.168.2.2 'sudo bash -c "
  printf \"export ML_ENABLED=true\nexport IMMICH_MACHINE_LEARNING_URL=http://192.168.2.105:3003\n\" \
    > /var/packages/immich/var/ml-settings.env
" && sudo /usr/syno/bin/synopkg restart immich'
```

---

## Manual build (without upgrading NAS)

```bash
# 1. Build on vm105
ssh narender@192.168.2.105 '
  rm -rf /tmp/immich-src /tmp/immich-out
  git clone https://github.com/immich-app/immich.git --branch v3.0.1 --depth 1 /tmp/immich-src
'
ssh narender@192.168.2.105 'cat > /tmp/vm-immich-build.sh' < syno/vm-immich-build.sh
ssh narender@192.168.2.105 'bash /tmp/vm-immich-build.sh'

# 2. Fetch artifacts
mkdir -p /tmp/immich-spk-work
ssh narender@192.168.2.105 'cat /tmp/immich-out/server-linux-x64.tar.gz' \
  > /tmp/immich-spk-work/server-linux-x64.tar.gz
ssh narender@192.168.2.105 'cat /tmp/immich-out/web-build.tar.gz' \
  > /tmp/immich-spk-work/web-build.tar.gz

# 3. Assemble SPK
VERSION=3.0.1-1 COPYFILE_DISABLE=1 bash syno/assemble-hybrid.sh
# Output: immich-x86_64-3.0.1-1.spk
```

---

## Key paths on NAS

| Path | Purpose |
|------|---------|
| `/volume1/@appstore/immich/` | Installed package root |
| `/var/packages/immich/var/pgdata/` | PostgreSQL data (survives upgrades) |
| `/var/packages/immich/var/ports.env` | Persisted DB/Redis port selection |
| `/var/packages/immich/var/ml-settings.env` | ML URL + enabled flag (config-ui writes here) |
| `/var/packages/immich/var/config-ui/` | Persisted config UI (server.cjs + index.html) |
| `/var/packages/immich/target/log/` | All runtime logs |
| `/volume1/docker/immich/upload/` | Photo library storage |

## Logs

```bash
# Startup sequence (redis→postgres→immich)
tail -f /var/packages/immich/target/log/start-stop-status.log

# Immich server (API + microservices)
tail -f /var/packages/immich/target/log/server.log

# PostgreSQL
tail -f /var/packages/immich/target/log/postgres.log
```

## Troubleshooting

**Port 2283 not listening after install**
```bash
ssh narender@192.168.2.2 'tail -30 /var/packages/immich/target/log/start-stop-status.log'
ssh narender@192.168.2.2 'tail -30 /var/packages/immich/target/log/postgres.log'
```

**ML unhealthy in Immich**
```bash
# ML container logs
ssh narender@192.168.2.105 'docker logs immich-ml --tail 20'
# ML URL seen by running process
ssh narender@192.168.2.2 'pid=$(cat /var/packages/immich/target/run/immich-server.pid)
  sudo cat /proc/$pid/environ | tr "\0" "\n" | grep IMMICH_MACHINE'
```

**Thumbnails missing after Docker → SPK migration**
All thumbnail files were in Docker volumes that are now gone. Trigger regeneration:
Immich Admin UI → Jobs → Thumbnail Generation → Force run all.

**PostgreSQL picks wrong port (conflict with DSM's postgres on 5432)**
Dynamic port selection in `start-stop-status` scans upward from 5432.
Check current port: `ssh narender@192.168.2.2 'cat /var/packages/immich/var/ports.env'`

---

## Package layout (inside package.tgz)

```
/var/packages/immich/target/
├── bin/            immich-server wrapper (injects IMMICH_BUILD_DATA, DB_VECTOR_EXTENSION)
├── server/         NestJS dist + production linux-x64 node_modules (built on vm105)
├── www/            SvelteKit static build (server reads ${IMMICH_BUILD_DATA}/www/)
├── node/           Node.js 24 linux-x64 (from 2.7.5-1 base SPK)
├── postgres/       PostgreSQL 14 + pgvector (from 2.7.5-1 base SPK)
├── redis/          Redis static musl x86_64 (from 2.7.5-1 base SPK)
├── geodata/        Reverse geocoding data (from 2.7.5-1 base SPK)
├── config-ui/      ML config UI (port 2284) — bootstrapped to var/config-ui/ on first start
└── conf/           Runtime config (immich.conf, sourced by start-stop-status)
```

The hybrid approach reuses binary deps (postgres/redis/node/geodata) from
`immich-x86_64-2.7.5-1.spk` and injects a freshly-built server + web on top.
`COPYFILE_DISABLE=1` prevents macOS `._*` resource fork files in tarballs.
