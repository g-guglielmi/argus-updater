# Changelog

All notable changes to argus-updater are documented here.
The format is based on [Keep a Changelog](https://keepachangelog.com/), and the project
follows [Semantic Versioning](https://semver.org/) (`MAJOR.MINOR.PATCH`).

Each release is a git tag `vX.Y.Z`: CI builds the version-pinned image (`:X.Y.Z`, `:X.Y`) and
publishes a GitHub Release from the matching section below. The tag build fails if the section is
missing, so add it before tagging. Pushes to `main` that touch `deploy/updater/` publish `:latest`
without a Release; collect those changes under **Unreleased** until the next tag.

---

## [Unreleased]

## [0.2.11] - 2026-10-02

### Added
- The `core` mode keeps the core host's collectors current. The core's Zabbix server is a host
  package, so the external checks it runs for the hosts it monitors (HTTP, TCP, SSH, UPS and the
  rest) never came with an Argus update: they stayed as setup installed them. Now, whenever the core's
  image changes, the sidecar runs that image once (as root, no network, only the host's
  `/usr/lib/zabbix/externalscripts` bound in) and it copies in the collectors that changed; again a
  day later, to put back a deleted or edited one, and ten minutes after a failure. The outcome goes to
  `collectors.json` in the shared dir and shows in the core's Settings. An Argus image from before
  this, or a host with no such folder, is skipped. `ARGUS_COLLECTORS_DIR` sets another folder.

## [0.2.10] - 2026-09-29

### Added
- A Docker `HEALTHCHECK` (`/app/healthcheck.sh`): healthy while the Docker Engine answers `/_ping` on
  the socket and, in the `core` and `probe-watch` modes, while the watch loop keeps going round. Each
  round writes a heartbeat with how long the next one may take (an update or a proxy recreate
  included, about half an hour of margin); a loop stuck past it is unhealthy. The one-shot
  `probe-recreate` mode checks the socket only. Every 30 s, unhealthy after 3 failures.

## [0.2.9] - 2026-09-29

### Added
- `probe-watch` restarts the proxy (Engine API restart, no recreate) when Argus answers a check-in
  with `restart_proxy`: the proxy reads its Zabbix process counts only at start, and Argus now sizes
  them from the probe's load. The sidecar advertises the ability (`restarts`); a proxy recreated in
  the same round already runs the new counts and is not restarted again.

## [0.2.8] - 2026-09-29

### Fixed
- The digest the core hands out was rejected as malformed by the shape check (a shell pattern that
  misbehaved), so every update in 0.2.7 fell back to "no digest handed out; applying unverified".
  The check is now a length + prefix + hex test; verified pulls log `verified: sha256:...`.

## [0.2.7] - 2026-09-29

### Security
- **Pulled images are verified against the digest the core handed out.** Tags stay tags (`latest`,
  `testing`, a version); the core now sends, with each tag, the digest it pointed to at hand-out
  time (probe check-in: `target_digest`, `update_digest`, `updater_update_digest`; core request:
  `digests` per tag; updater request: `digest`), and every mode compares the pulled image's
  repository digest against it before recreating anything. A mismatch is refused and logged, the
  container left untouched. The self-update helper image is pulled and verified the same way before
  it is run (it no longer uses `--pull always`). No digest (an older core, the registry unreachable
  at hand-out) means the tag is applied unverified, with a log line, as before.
- CI: actions pinned to commits, permissions granted per job, provenance and SBOM attestations on
  the image.

## [0.2.6] - 2026-09-28

### Security
- The probe-watch sidecar reads the proxy's `proxy.env` as data (one key at a time, each checked
  for shape) instead of sourcing it as shell. The file's values arrive from the network through
  another container, and this container holds the Docker socket: a crafted value used to run as
  root here.
- Every image tag the core hands out (fleet target, one-shot update, updater self-update) and every
  tag in a core update request is checked before it becomes an image reference; anything that isn't
  a plain tag is ignored with a log line.
- A plain-http check-in URL is refused unless `ARGUS_ALLOW_INSECURE_CHECKIN=true` (the sidecar's
  token would otherwise travel in clear).
- The shared update directory is handed to the core (uid 65532) and made `0750`, no longer
  world-writable: a request file there is an instruction to the socket holder, so other accounts on
  the host must not be able to drop one.

### Added
- A changelog (this file) that now feeds the GitHub Release notes.

### Changed
- Maintenance: test and documentation tidy-ups. No change to the updater's behaviour.

## [0.2.4] - 2026-09-15

### Fixed
- Recreating a container now keeps its network identity: static IP, MAC address, network aliases
  and hostname survive an image swap (they were dropped before).

### Added
- A regression test for the recreate config clone, run in CI before every image build.

### Changed
- Relicensed from MIT to AGPL-3.0; SPDX headers on all source files.

## [0.2.3] - 2026-09-02

### Fixed
- The updater identifies its own container reliably (via the mount table instead of the hostname),
  so it no longer targets the wrong container when self-updating.

## [0.2.2] - 2026-09-02

### Fixed
- The self-update helper is always started from a freshly pulled image.

## [0.2.1] - 2026-09-02

### Fixed
- Image pulls are retried, and the self-update helper's logs are kept for troubleshooting.

## [0.2.0] - 2026-09-02

### Added
- One multi-mode updater image for the core and the probes: `core` (file channel from the Argus
  settings page), `probe-watch` (socket-holding sidecar next to each probe, no compose needed) and
  `probe-recreate` (one-shot recreate primitive).
- The updater reports its own version and can update itself on request.

### Removed
- The old `probe-poll` mode, replaced by `probe-watch`.

## [0.1.0] - 2026-09-01

### Added
- First release: one-click core self-update. The sidecar holds the Docker socket so the core never
  does, pulls the new image, recreates the core with its existing config, verifies health and rolls
  back on failure.
- Switch release channel or pin a version from the Argus GUI; channel-preserving updates.
