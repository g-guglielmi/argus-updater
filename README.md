<p align="center"><img src="argus-logo.png" alt="Argus" width="110"></p>

# argus-updater

The self-update sidecar for [Argus](https://github.com/g-guglielmi/argus-core). A small
socket-holding container that recreates the **core** container on a new image — pull → recreate
cloning the running config → health-verify → roll back on failure — so the public-facing core never
needs to hold the Docker socket itself.

- **`deploy/updater/`** — the `argus-updater` image (`ghcr.io/g-guglielmi/argus-updater`), its
  `core-update.sh` recreate logic, and a compose example.

Triggered from the core's **Settings → update** flow (see argus-core).

## Roadmap

Generalize this into one updater used by **both** the core and probes — replacing the probe image's
bundled `updater.sh`/`recreate.sh` — so there's a single maintained socket-holding recreate mechanism.
Tracked in the argus-core roadmap (§A).

## Related

- **[argus-core](https://github.com/g-guglielmi/argus-core)** — the app it updates.
- **[argus-probe](https://github.com/g-guglielmi/argus-probe)** — the monitoring probe (image + VM).
