# Immich Synology SPK

Native Synology NAS package for Immich — no Docker required on the NAS.

| Field | Value |
|-------|-------|
| Architecture | x86_64 |
| DSM minimum | 7.2-64561 |
| Immich port | 2283 |
| Config UI port | 2284 |

---

## Native DSM updates: source hooks, not an activated update service

**Package Center's one-click Update path is not operationally verified here.**
Three separate things are required:

1. **Publication:** a reviewed release must publish matching native SPKs containing
   these new hooks. Existing published SPKs do not acquire hooks from this source edit.
2. **Compatible catalog and registration:** `packages.json` remains a static catalog,
   with offline identity/version/architecture/link checks only. A raw GitHub JSON URL
   has not been proven compatible with DSM Package Sources, including HTTP method and
   architecture selection. A compatible endpoint must be validated separately before
   an administrator adds it in **Package Center → Settings → Package Sources**.
   No source is automatically registered; the old unsupported `feeds.conf` write is
   removed. Neither registration nor the Update button's visibility has been verified.
3. **Native upgrade testing:** once a compatible source advertises a newer matching
   package, the user clicks **Update** in Package Center. Alternatively, after trusted
   artifact publication, use DSM's **Manual Install** with the matching newer SPK.
   These use DSM's native installation lifecycle, not a root updater or config-UI API.

No server, root hook, scheduler, unattended installer or new update UI is provided.
The existing `upgrade.sh` is an unrelated operator source-build routine, not the
native click-update implementation. Do not schedule it as a NAS updater.

### Pre-upgrade backup and configuration preservation

Standalone assembly ships `scripts/preupgrade`, `scripts/postinst`,
`scripts/postupgrade`, and `update_protocol.py` (stdlib Python 3.8+, DSM
`/usr/bin/python3`). Existing package-level `conf/privilege` remains unchanged.
According to [DSM's lifecycle order](https://help.synology.com/developer-guide/synology_package/scripts.html#upgrade),
DSM stops the old package, then executes the **new** preupgrade hook before old
removal hooks; [the upgrade temporary directory](https://help.synology.com/developer-guide/synology_package/script_env_var.html)
is used to hand off the preservation reference.

The package-user preupgrade hook refuses to continue unless the old bundled
`pg_controldata` is present, reports PostgreSQL **14**, and reports the PGDATA
cluster exactly **shut down**. A `postmaster.pid`, other major version, unclean
shutdown, external tablespace/symlink, unsafe ownership/mode, insufficient free
space, or any copy/checksum failure aborts the upgrade before old removal.
It does not connect to a live DB or DSM's system database, guess a role/port,
restart PostgreSQL, or run `pg_dump` against a stopped server.

Each attempt retains a cold physical copy of `var/pgdata`, plus exact bytes of
`target/conf/immich.conf`, `var/ports.env`, and `var/ml-settings.env`, under:

```
/var/packages/immich/var/update-backups/attempt-<id>/
    pgdata/          complete cold PostgreSQL 14 cluster copy
    config          preserved immich.conf (contains secrets; mode 0600)
    ports, ml       preserved when present
    manifest.json   sizes/SHA256 hashes, no configuration values
    status.json     pending / failed / ready / config-restored
```

The backup directory is owned by the package user, mode 0700, outside replaceable
`target`; existing old `postuninst` does not delete it or PGDATA. Copies are
byte-verified, source stability is checked again, and successful and failed
snapshots are retained without pruning. Budget at least the PGDATA size plus
20% and 16 MiB on the package-data volume **in addition to DSM installation space**.
Large databases require a long maintenance window and repeated checksum reads.

New postinst validates the retained snapshot and unchanged live PGDATA, requires
the new bundled tool to remain PostgreSQL 14, and restores all three config files
**before** defaults/config handling or startup. This preserves custom upload paths,
DB settings, ports and ML settings without evaluating shell configuration in hooks.
Missing/corrupt preservation fails closed, leaving `.update-required` present;
startup checks that gate before sourcing configuration. A pending/failed/not-yet-
restored attempt prevents another backup/upgrade until manually investigated.
`config-restored` means only preservation finished, **not successful DB restoration,
application startup, migrations, or endpoint health**.

### Recovery limits and validation

This is a physical PostgreSQL 14 cluster snapshot, not a portable logical dump,
media backup, PITR system, or proof of restoration. No external tablespaces are
supported. Keep independent photo/video backups and the compatible old PostgreSQL
binaries/extensions/configuration needed for a recovery rehearsal on another NAS.
Do not delete failure markers or snapshots merely to retry migrations. There is
no automatic DB restore, binary downgrade, uninstall or photo deletion. Major PG
upgrades and application/schema rollback require a separately tested recovery plan.

Actual DSM hook permissions/temp-folder persistence, artifact publication, feed
protocol/registration, native upgrade/startup and physical restore have **not been
proven on a NAS** by these source/offline tests. After a separately authorized test
upgrade, verify the installed package version, actual `/api/server/version`,
`/api/server/ping`, migration results and photo access; an open port is insufficient.
Nothing in this change activates or modifies a live NAS.

Offline tests (no network, service, installation, scheduler or real PG binaries):

```sh
mkdir -p /tmp/immich-spk/tests
TMPDIR=/tmp/immich-spk/tests uv run --no-project --no-python-downloads --python /usr/bin/python3 python -m unittest discover -s syno/tests
```

## Operator source-build upgrade (not NAS scheduling)

The existing operator routine builds remotely and installs to a configured NAS:

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
