# argus-updater: the socket-holding sidecar that performs Argus *core* self-updates on the core's
# behalf. The public-facing core never gets the Docker socket; this small, non-web-facing helper does.
#
# It watches a directory shared with the core (ARGUS_UPDATE_DIR, e.g. /update): when the core drops a
# request.json (an admin clicked "Update now"), it pulls the target image, recreates the core container
# cloning its config, verifies the new container stays healthy, rolls back on failure, and writes the
# outcome back to status.json so the core can show a banner.
#
# Run it alongside the core (see deploy/core/docker-compose.yml):
#   docker run -d --name argus-updater --restart unless-stopped \
#     -v /var/run/docker.sock:/var/run/docker.sock \
#     -v argus-update:/update \
#     -e ARGUS_CORE_CONTAINER=argus \
#     ghcr.io/g-guglielmi/argus-updater:latest
FROM alpine:3.20

# docker-cli: pull + talk to the Engine API. curl: Engine API over the unix socket + a best-effort
# /healthz probe of the new core. jq: read/write the JSON channel files.
RUN apk add --no-cache curl jq docker-cli

# Bake the image version so it can be surfaced later if needed; "dev" for local builds.
ARG UPDATER_VERSION=dev
RUN echo "$UPDATER_VERSION" > /etc/argus-updater.version
LABEL io.argus.updater.version=$UPDATER_VERSION

COPY core-update.sh /usr/local/bin/argus-core-update.sh
RUN chmod +x /usr/local/bin/argus-core-update.sh

ENTRYPOINT ["/usr/local/bin/argus-core-update.sh"]
