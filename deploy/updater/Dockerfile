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
FROM alpine:3.20

# docker-cli: `docker pull` + talk to the Engine API. curl: Engine API over the unix socket + a
# best-effort /healthz probe of the new core. jq: read/write the JSON channel files. (No compose
# plugin: every mode recreates via the Engine API, not `docker compose`.)
RUN apk add --no-cache curl jq docker-cli

# Bake the image version so it can be surfaced later if needed; "dev" for local builds.
ARG UPDATER_VERSION=dev
RUN echo "$UPDATER_VERSION" > /etc/argus-updater.version
LABEL io.argus.updater.version=$UPDATER_VERSION

# The dispatcher + the shared engine and per-mode scripts.
COPY entrypoint.sh /usr/local/bin/argus-updater
COPY lib/   /usr/local/lib/argus-updater/lib/
COPY modes/ /usr/local/lib/argus-updater/modes/
RUN chmod +x /usr/local/bin/argus-updater

ENTRYPOINT ["/usr/local/bin/argus-updater"]
