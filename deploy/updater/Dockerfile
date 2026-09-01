# argus-updater: one socket-holding sidecar that recreates a target container on a new image, shared
# by BOTH the Argus core and the argus-probe proxies. The public-facing core (and the outbound-only
# probes) never hold the Docker socket; this small, non-web-facing helper does.
#
# The recreate engine (pull -> clone the running config -> verify healthy -> roll back on failure) is
# one library used by every mode, so the core and probe update paths can never drift. Pick a mode
# with ARGUS_UPDATER_MODE (default: core):
#   core            watch the shared /update dir and recreate the CORE on an admin's "Update now".
#   probe-recreate  one-shot: recreate the argus-probe PROXY on a new image, then exit.
#   probe-poll      compose sidecar: poll Argus for the fleet target and converge the proxy.
#
# Core deployment (see deploy/updater/docker-compose.yml):
#   docker run -d --name argus-updater --restart unless-stopped \
#     -v /var/run/docker.sock:/var/run/docker.sock \
#     -v argus-update:/update \
#     -e ARGUS_CORE_CONTAINER=argus \
#     ghcr.io/g-guglielmi/argus-updater:latest
FROM alpine:3.20

# docker-cli: pull + talk to the Engine API. docker-cli-compose: the `docker compose` plugin the
# probe-poll mode drives. curl: Engine API over the unix socket + a best-effort /healthz probe. jq:
# read/write the JSON channel files.
RUN apk add --no-cache curl jq docker-cli docker-cli-compose

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
