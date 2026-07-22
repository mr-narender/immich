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

ML inference runs on a separate Docker-capable host (not the NAS itself):

```bash
docker run -d --name immich-ml -p 3003:3003 \
  -v immich-ml-cache:/cache \
  -e MACHINE_LEARNING_CACHE_FOLDER=/cache \
  --restart unless-stopped \
  ghcr.io/immich-app/immich-machine-learning:latest
```

Enter the ML URL (`http://<docker-host-ip>:3003`) in the Immich config UI at `http://<NAS-IP>:2284`.

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
