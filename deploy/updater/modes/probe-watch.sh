# shellcheck shell=sh
# argus-updater - mode: probe-watch (opt-in socket-holding sidecar; NO compose).
#
# For plain `docker run` proxies (e.g. managed with Dockhand): a tiny sidecar holds the Docker socket
# and recreates the proxy via the Docker Engine API when Argus signals an update - so the PROXY
# container itself never needs the socket (the same principle as the core's updater), and no compose
# is involved. This is the recommended self-update model for docker-run proxies.
#
# It reads the proxy's check-in credential from the proxy's data volume (mounted read-only at /probe),
# polls Argus advertising self-update capability (but reporting no version - the proxy reports its own
# authoritative version), and converges the proxy through the shared engine (config-clone + verify +
# rollback) on either:
#   - a dashboard "Update now" (the one-shot {"update":"<tag>"}) - always recreates (re-pulls the tag,
#     so a rolling :latest picks up a newer digest); or
#   - a fleet-target change - recreates only when the target tag differs from what the proxy runs.
#
# Deploy alongside a proxy (the proxy stays socket-free):
#   docker run -d --name <proxy>-updater --restart unless-stopped \
#     -v /var/run/docker.sock:/var/run/docker.sock \
#     -v <proxy-data-dir>:/probe:ro \
#     -e ARGUS_UPDATER_MODE=probe-watch \
#     -e ARGUS_PROXY_CONTAINER=<proxy-container-name> \
#     ghcr.io/g-guglielmi/argus-updater:latest
set -eu

META="${ARGUS_PROBE_META:-/probe/enroll/proxy.env}"
INTERVAL="${ARGUS_UPDATE_INTERVAL:-300}"
PROXY_CONTAINER="${ARGUS_PROXY_CONTAINER:-}"
PROBE_IMAGE="${ARGUS_PROBE_IMAGE:-ghcr.io/g-guglielmi/argus-probe}"
RECREATE_NOUN="proxy"

log()      { echo "argus-updater[watch]: $*"; }
progress() { echo "argus-updater[watch]: $*"; }

# resolve_proxy - the proxy container name to manage: the configured one if it exists, else the first
# running container whose image repo matches PROBE_IMAGE. Empty if none found yet.
resolve_proxy() {
  if [ -n "$PROXY_CONTAINER" ]; then
    if api GET "/containers/$PROXY_CONTAINER/json" | jq -e '.Id' >/dev/null 2>&1; then
      echo "$PROXY_CONTAINER"; return 0
    fi
  fi
  api GET "/containers/json" \
    | jq -r --arg repo "$PROBE_IMAGE" '.[] | select((.Image | split(":")[0]) == $repo) | .Names[0] // empty' \
    | sed 's#^/##' | head -n1
}

log "starting (poll ${INTERVAL}s, proxy=${PROXY_CONTAINER:-<by image $PROBE_IMAGE>})"
while true; do
  PROBE_TOKEN=""; CHECKIN_URL=""
  [ -f "$META" ] && { . "$META" 2>/dev/null || true; }

  if [ -n "$PROBE_TOKEN" ] && [ -n "$CHECKIN_URL" ]; then
    # Advertise capability + read the target/one-shot. No version (the proxy reports its own).
    RESP=$(curl -sS -m 15 -H "Authorization: Bearer $PROBE_TOKEN" -H 'Content-Type: application/json' \
      -d "$(jq -nc '{selfupdate:true}')" "$CHECKIN_URL" 2>/dev/null || echo '')
    TARGET=$(echo "$RESP" | jq -r '.target // empty' 2>/dev/null || true)
    UPDATE=$(echo "$RESP" | jq -r '.update // empty' 2>/dev/null || true)

    NAME=$(resolve_proxy || true)
    if [ -z "$NAME" ]; then
      log "no proxy container found yet (looked for '${PROXY_CONTAINER:-any}' / image $PROBE_IMAGE) - will retry"
    else
      CUR_IMAGE=$(api GET "/containers/$NAME/json" | jq -r '.Config.Image // empty')
      REPO=$(image_repo "$CUR_IMAGE"); [ -z "$REPO" ] && REPO="$PROBE_IMAGE"
      CUR_TAG=$(image_tag "$CUR_IMAGE"); [ -z "$CUR_TAG" ] && CUR_TAG="latest"

      # A one-shot dashboard update forces a recreate (re-pull the tag, even :latest); otherwise
      # converge on the fleet target only when its tag differs from the running one.
      DESIRED=""; FORCE=0
      if [ -n "$UPDATE" ]; then
        DESIRED="latest"; [ "$UPDATE" != "latest" ] && DESIRED="$UPDATE"; FORCE=1
      elif [ -n "$TARGET" ]; then
        DESIRED="latest"; [ "$TARGET" != "latest" ] && DESIRED="$TARGET"
      fi

      if [ -n "$DESIRED" ] && { [ "$FORCE" = "1" ] || [ "$DESIRED" != "$CUR_TAG" ]; }; then
        log "converging $NAME: $CUR_TAG -> $DESIRED (force=$FORCE)"
        if recreate_container "$NAME" "$REPO:$DESIRED"; then
          log "$NAME updated to $REPO:$DESIRED"
        else
          log "update failed: $RECREATE_ERR" >&2
        fi
      fi
    fi
  fi

  sleep "$INTERVAL"
done
