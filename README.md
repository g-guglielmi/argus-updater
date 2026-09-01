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
| `probe-watch` | long-running | **The probe updater** (run / compose / VM). A socket-holding sidecar that recreates the proxy via the Engine API on a dashboard "Update now" or a target change — so the **proxy stays socket-free**, same as the core. Also updates **itself** on request via the primitive below. |
| `probe-recreate` | one-shot | Recreate a target container on a new image, then exit. The self-update **primitive**: a long-running updater spawns an ephemeral `--rm` copy of itself in this mode to recreate itself. |

Every mode recreates via the **Docker Engine API** (no `docker compose` dependency). The `core` mode
is triggered from the core's **Settings → update** flow; `probe-watch` is driven by Argus fleet
updates (see the argus-probe / argus-core repos).

**probe-watch** — run one alongside each proxy (the proxy needs **no** socket):

```bash
docker run -d --name <proxy>-updater --restart unless-stopped \
  -v /var/run/docker.sock:/var/run/docker.sock \
  -v <proxy-data-dir>:/probe:ro \
  -e ARGUS_UPDATER_MODE=probe-watch \
  -e ARGUS_PROXY_CONTAINER=<proxy-container-name> \
  ghcr.io/g-guglielmi/argus-updater:latest
```

**Versioning:** a rolling `:latest` (tracks `main`) plus version-pinned images (`:X.Y.Z`, `:X.Y`) and a GitHub Release cut from each `vX.Y.Z` tag — pin a version in production if you'd rather not track `:latest`.

## Related

- **[argus-core](https://github.com/g-guglielmi/argus-core)** — the app it updates.
- **[argus-probe](https://github.com/g-guglielmi/argus-probe)** — the monitoring probe (image + VM) whose proxies it also updates.
