<p align="center"><img src="argus-logo.png" alt="Argus" width="110"></p>

# argus-updater

The shared self-update sidecar for [Argus](https://github.com/g-guglielmi/argus-core). One small
socket-holding container that recreates a target container on a new image — pull → recreate cloning
the running config → health-verify → roll back on failure — used by **both** the core and the
[argus-probe](https://github.com/g-guglielmi/argus-probe) proxies, so the public-facing core (and the
outbound-only probes) never need to hold the Docker socket themselves.

- **`deploy/updater/`** — the `argus-updater` image (`ghcr.io/g-guglielmi/argus-updater`): the shared
  recreate engine (`lib/recreate.sh`), the per-mode scripts (`modes/`), and a compose example.

## Modes

One image, picked with `ARGUS_UPDATER_MODE` (default `core`, so an existing core sidecar that sets no
mode keeps working unchanged). The recreate engine is shared, so the paths can never drift.

| Mode | Lifetime | What it does |
|------|----------|--------------|
| `core` *(default)* | long-running | Watch the shared `/update` dir; recreate the **core** when an admin clicks **Settings → Update now**. `/healthz`-aware; preserves the release channel (`:latest`/`:testing`). |
| `probe-recreate` | one-shot | Recreate the argus-probe **proxy** on a new image, then exit. Spawned by the proxy as a `--rm` sister container (a container can't `rm -f` itself mid-update). |
| `probe-poll` | long-running | Opt-in compose sidecar: poll Argus for the fleet target and converge the proxy via `docker compose` (keeps the compose `.env` authoritative). |

The `core` mode is triggered from the core's **Settings → update** flow; the two probe modes are
driven by the argus-probe image (see that repo). `probe-poll` uses the bundled `docker compose`
plugin; the other modes talk to the Docker Engine API directly.

**Versioning:** a rolling `:latest` (tracks `main`) plus version-pinned images (`:X.Y.Z`, `:X.Y`) and a GitHub Release cut from each `vX.Y.Z` tag — pin a version in production if you'd rather not track `:latest`.

## Related

- **[argus-core](https://github.com/g-guglielmi/argus-core)** — the app it updates.
- **[argus-probe](https://github.com/g-guglielmi/argus-probe)** — the monitoring probe (image + VM) whose proxies it also updates.
