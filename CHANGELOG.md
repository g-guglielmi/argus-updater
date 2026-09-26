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

## [0.2.5] - 2026-09-26

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
