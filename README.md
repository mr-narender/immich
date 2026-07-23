# Immich Synology NAS Package (SPK)

Automated Synology Package Center SPK for [Immich](https://github.com/immich-app/immich) — high-performance self-hosted photo and video management.

Builds are triggered automatically every 6 hours. New upstream Immich releases produce a new SPK release within 6 hours.

---

## Disclaimer & Credits

**I am not affiliated with the Immich project in any way.**

All credit for the application itself belongs entirely to the [immich-app](https://github.com/immich-app) team and its contributors — they built something remarkable and I deeply respect their work.

What this repo provides is purely a **packaging layer**: a way to install Immich on a Synology NAS as a native package (SPK) without running Docker on the NAS itself. The Immich source code is untouched — only the Synology wrapper scripts and CI automation live here.

This is shared freely for anyone who finds it useful. If you want to support the effort that went into building and maintaining this packaging:

- [Buy Me a Coffee ☕](https://buymeacoffee.com/mr.narender)
- [GitHub Sponsors ❤️](https://github.com/sponsors/mr-narender)

For Immich itself — support their project directly at [immich.app](https://immich.app).

---

## Why this package vs SynoCommunity's Immich package

[SynoCommunity](https://synocommunity.com/package/immich) also publishes an Immich SPK — it is well-maintained and the right choice if you already use their ecosystem.

This package takes a different approach:

| | This package | SynoCommunity |
|---|---|---|
| Pre-requisites | None — fully self-contained | 6 packages required (Node.js, PostgreSQL, Redis, Perl, Python, ffmpeg) |
| ML inference | Offloaded to external Docker host (GPU-capable) | Runs on the NAS itself (NAS CPU only) |
| NAS RAM impact | Zero ML load — NAS stays fast | ML inference competes with Immich for NAS RAM |
| PostgreSQL | Bundled PG14 + pgvector, version-pinned | Depends on SynoCommunity's postgres (version drift risk) |
| Auto-updates | Within 6 hours of each Immich release | Manual — maintainer driven |

**Choose this package if:** you want a zero-dependency drop-in, don't want ML burning NAS resources, or want faster release tracking.

**Choose SynoCommunity if:** you already have their ecosystem installed and want on-NAS ML without an external machine.

---

## Install via Package Center (recommended)

1. DSM → Package Center → Settings → Package Sources → Add:
   ```
   https://raw.githubusercontent.com/mr-narender/immich/main/packages.json
   ```
2. Search for **Immich** in Package Center → Install.
3. Follow the install wizard (sets data folder, optional ML URL).

Future upgrades appear automatically in Package Center.

---

## Manual Install

Download the latest `.spk` from [Releases](https://github.com/mr-narender/immich/releases), then:

DSM → Package Center → Manual Install → upload the `.spk`.

---

## Machine Learning (optional)

Immich ML powers face recognition, semantic search ("dog on beach"), and object/scene tagging. This package deliberately does **not** run ML on the NAS — NAS CPUs (Celeron, Atom) lack the AVX2 instructions needed for fast inference, and ML models consume 2–4 GB of RAM that competes with Immich, PostgreSQL, and Redis on a RAM-constrained device.

Instead, ML runs on a separate Docker-capable host — any spare x86 machine, a mini PC, or a machine with an NVIDIA GPU for 10–100× faster processing of large libraries.

### What works without ML

Everything except smart features:

| Feature | Needs ML? |
|---|---|
| Photo/video viewing, upload, backup | No |
| Albums, sharing, timeline | No |
| Map view (geodata bundled) | No |
| Search by date, location, album | No |
| Face recognition ("People" view) | **Yes** |
| Smart/semantic search | **Yes** |
| Object and scene auto-tagging | **Yes** |

### Setup (CPU — any Docker host)

```bash
docker run -d --name immich-ml \
  -p 3003:3003 \
  -v immich-ml-cache:/cache \
  -e MACHINE_LEARNING_CACHE_FOLDER=/cache \
  --restart unless-stopped \
  ghcr.io/immich-app/immich-machine-learning:latest
```

### Setup (NVIDIA GPU — optional, 10–100× faster)

```bash
docker run -d --name immich-ml \
  -p 3003:3003 \
  -v immich-ml-cache:/cache \
  -e MACHINE_LEARNING_CACHE_FOLDER=/cache \
  --gpus all \
  --restart unless-stopped \
  ghcr.io/immich-app/immich-machine-learning:latest-cuda
```

### Connect to Immich

In the Immich web UI at `http://<NAS-IP>:2284`:

**Administration → Machine Learning Settings → URL** → set to `http://<docker-host-ip>:3003`

The first run downloads models (~1.5 GB into the cache volume). Subsequent starts are instant.

---

## Repo Layout

```
.github/workflows/auto-release.yml   — CI: detect → build → release → update feed
syno/                                 — Synology overlay (scripts, configs, wizard)
  assemble-hybrid.sh                  — SPK assembly (server tar + web tar + base SPK)
  INFO                                — Package metadata (version, changelog)
  src/scripts/start-stop-status       — DSM lifecycle hooks
  config-ui/                          — Web config UI (port 2284)
  docker/                             — Helper Dockerfiles (postgres+pgvector, ML)
packages.json                         — Package Center custom source feed (auto-updated by CI)
immich/                               — Git submodule: immich-app/immich (pinned to current release)
```

---

## How CI Works

1. **Detect** — every 6 hours, polls `immich-app/immich` latest release. Skips if SPK release already exists.
2. **Build** — shallow-clones Immich at the release tag, builds server + web with Node 24 / pnpm, prunes non-linux-x64 native prebuilds, packages tarballs.
3. **Assemble** — combines tarballs with `syno/assemble-hybrid.sh` on top of a base SPK (contains postgres, redis, node runtime, geodata).
4. **Release** — creates a GitHub Release with the `.spk` artifact, updates `packages.json` feed, commits the version bump + submodule pointer, pushes to `main`.

To force a specific version: Actions → Auto Release Synology SPK → Run workflow → enter version (e.g. `3.0.2`).

---

## Base SPK

The base SPK (`base-deps-<version>`) contains binary dependencies (PostgreSQL with pgvector, Redis static, Node runtime, geodata) pre-built for Synology x86_64. Upload a new base SPK release tagged `base-deps-<version>` before bumping the version reference in `auto-release.yml`.

---

## Contributing

- Overlay scripts live in `syno/` — PRs welcome for DSM compatibility fixes.
- Do **not** modify files under `immich/` — that directory is a read-only submodule pointer.
- Upstream bugs → [immich-app/immich](https://github.com/immich-app/immich/issues).
