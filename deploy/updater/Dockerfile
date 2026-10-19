# argus-updater: one socket-holding sidecar that recreates a target container on a new image, shared
# by BOTH the Argus core and the argus-probe proxies. The public-facing core (and the outbound-only
# probes) never hold the Docker socket; this small, non-web-facing helper does.
#
# The recreate engine (pull -> clone the running config -> verify healthy -> roll back on failure) is
# one library used by every mode, so the core and probe update paths can never drift. Pick a mode
# with ARGUS_UPDATER_MODE (default: core):
#   core            watch the shared /update dir and recreate the CORE on an admin's "Update now".
#   probe-watch     socket-holding sidecar: recreate the PROXY via the Engine API on a fleet update
#                   - the proxy stays socket-free. The one probe updater (run/compose/VM).
#   probe-recreate  one-shot: recreate a target container on a new image, then exit (the primitive
#                   the updater uses to update itself).
#
# Core deployment (see deploy/updater/docker-compose.yml):
#   docker run -d --name argus-updater --restart unless-stopped \
#     -v /var/run/docker.sock:/var/run/docker.sock \
#     -v argus-update:/update \
#     -e ARGUS_CORE_CONTAINER=argus \
#     ghcr.io/g-guglielmi/argus-updater:latest
# Pinned by digest as well as by tag: a tag can be re-pointed upstream without any change here, a
# digest can't. Dependabot (.github/dependabot.yml) moves the digest and the 3.x line with a
# reviewed pull request, as in the core repo.
FROM alpine:3.24@sha256:294b683cb724975bec92580e1e685676bd4b50bda910ddb8c51d4cabeaec77e6

# docker-cli: `docker pull` + talk to the Engine API. curl: Engine API over the unix socket + a
# best-effort /healthz probe of the new core. jq: read/write the JSON channel files. (No compose
# plugin: every mode recreates via the Engine API, not `docker compose`.)
# `apk upgrade` first: the base is pinned by digest, so its packages (musl, busybox, openssl, ...)
# would otherwise stay at the pin's versions; every build takes the 3.24 branch's current patches
# instead, and so does the weekly rebuild the core repo's scan asks for when a HIGH lands.
RUN apk upgrade --no-cache && apk add --no-cache curl jq docker-cli ca-certificates

# cosign verifies the Sigstore signature of every image before it is run (lib/recreate.sh,
# verify_signature): the official static binary, pinned by version and checksum.
ARG TARGETARCH=amd64
ARG COSIGN_VERSION=v3.1.3
RUN set -eu; case "$TARGETARCH" in amd64) sum=4629c757b7618056f8ddd7e2625ae9fdd94c0372a65049520bc7d9df9efc7f71 ;; arm64) sum=c5d324e091826b0d7a78eb16fef316450b4eb9aaec045611c08ba06f5e73220a ;; *) echo "no cosign checksum for $TARGETARCH" >&2; exit 1 ;; esac; curl -fsSL --retry 3 -o /usr/local/bin/cosign "https://github.com/sigstore/cosign/releases/download/${COSIGN_VERSION}/cosign-linux-${TARGETARCH}"; echo "$sum  /usr/local/bin/cosign" | sha256sum -c -; chmod 0755 /usr/local/bin/cosign; /usr/local/bin/cosign version

# Bake the image version so it can be surfaced later if needed; "dev" for local builds.
ARG UPDATER_VERSION=dev
RUN echo "$UPDATER_VERSION" > /etc/argus-updater.version
LABEL io.argus.updater.version=$UPDATER_VERSION

# The dispatcher + the shared engine and per-mode scripts.
COPY entrypoint.sh /usr/local/bin/argus-updater
COPY lib/   /usr/local/lib/argus-updater/lib/
COPY modes/ /usr/local/lib/argus-updater/modes/
RUN chmod +x /usr/local/bin/argus-updater

# Container health for Docker, the Unraid GUI or Dockhand: the Engine answers on the socket and the
# watch loop keeps going round (healthcheck.sh).
COPY healthcheck.sh /app/healthcheck.sh
RUN chmod 0755 /app/healthcheck.sh
HEALTHCHECK --interval=30s --timeout=10s --start-period=30s --retries=3 CMD ["/app/healthcheck.sh"]

ENTRYPOINT ["/usr/local/bin/argus-updater"]
