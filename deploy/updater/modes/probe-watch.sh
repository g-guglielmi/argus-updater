# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 g-guglielmi

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
UPDATER_REPO="${ARGUS_UPDATER_REPO:-ghcr.io/g-guglielmi/argus-updater}"
UPDATER_VERSION="$(cat /etc/argus-updater.version 2>/dev/null || echo dev)"
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
  # proxy.env is read as data: a token and a URL, each checked for shape. The proxy's data volume is
  # mounted read-only here, but its contents came from the network and from another container.
  PROBE_TOKEN=$(read_kv "$META" PROBE_TOKEN)
  CHECKIN_URL=$(read_kv "$META" CHECKIN_URL)
  case "$PROBE_TOKEN" in ''|*[!A-Za-z0-9._-]*) PROBE_TOKEN="";; esac
  if printf '%s' "$CHECKIN_URL" | grep -q '[^A-Za-z0-9.:/_%?=&-]'; then CHECKIN_URL=""; fi
  case "$CHECKIN_URL" in
    https://*|'') ;;
    http://*) [ "${ARGUS_ALLOW_INSECURE_CHECKIN:-}" = "true" ] || { log "refusing the plain-http check-in URL in $META (set ARGUS_ALLOW_INSECURE_CHECKIN=true to allow it)"; CHECKIN_URL=""; };;
    *) CHECKIN_URL="";;
  esac

  if [ -n "$PROBE_TOKEN" ] && [ -n "$CHECKIN_URL" ]; then
    # Advertise capability + report OUR (updater) version + read the target/one-shots. We report no
    # proxy version (the proxy reports its own); updater_version is our sidecar's own version.
    RESP=$(curl -sS -m 15 -H "Authorization: Bearer $PROBE_TOKEN" -H 'Content-Type: application/json' \
      -d "$(jq -nc --arg uv "$UPDATER_VERSION" '{selfupdate:true, updater_version:$uv}')" \
      "$CHECKIN_URL" 2>/dev/null || echo '')
    TARGET=$(echo "$RESP" | jq -r '.target // empty' 2>/dev/null || true)
    UPDATE=$(echo "$RESP" | jq -r '.update // empty' 2>/dev/null || true)
    UPDATER_UPDATE=$(echo "$RESP" | jq -r '.updater_update // empty' 2>/dev/null || true)
    # The digest each tag pointed to when the core handed it out; the pull must match (a malformed
    # one is dropped and the tag applied unverified, with a log line, as with an older core).
    TARGET_DIGEST=$(echo "$RESP" | jq -r '.target_digest // empty' 2>/dev/null || true)
    UPDATE_DIGEST=$(echo "$RESP" | jq -r '.update_digest // empty' 2>/dev/null || true)
    UPDATER_UPDATE_DIGEST=$(echo "$RESP" | jq -r '.updater_update_digest // empty' 2>/dev/null || true)
    for _v in TARGET_DIGEST UPDATE_DIGEST UPDATER_UPDATE_DIGEST; do
      eval "_t=\$$_v"
      if [ -n "$_t" ] && ! valid_digest "$_t"; then log "ignoring a malformed $_v from Argus"; eval "$_v=''"; fi
    done
    # Every tag the core hands out is checked before it becomes an image reference.
    for _v in TARGET UPDATE UPDATER_UPDATE; do
      eval "_t=\$$_v"
      if [ -n "$_t" ] && ! valid_tag "$_t"; then log "ignoring an invalid $_v tag from Argus"; eval "$_v=''"; fi
    done

    # Self-update: recreate OURSELVES via an ephemeral --rm copy running probe-recreate against our
    # own container (we can't rm -f ourselves). The ephemeral helper uses the NEW updater image so it
    # carries the latest recreate logic; it clones our config (mode, mounts, socket) onto the new tag.
    if [ -n "$UPDATER_UPDATE" ]; then
      SELF=$(self_container_id)
      # Name the helper (so `docker logs <name>` reaches it while it runs) but --rm it (auto-removed on
      # exit - no lingering container). --pull always so it runs the freshest image, never stale code.
      _sn=$(api GET "/containers/$SELF/json" 2>/dev/null | jq -r '.Name // empty' 2>/dev/null | sed 's#^/##')
      [ -z "$_sn" ] && _sn="argus-updater"
      HELPER="${_sn}-selfupdate"
      log "updater self-update to $UPDATER_UPDATE requested - spawning $HELPER (target $SELF)"
      docker rm -f "$HELPER" >/dev/null 2>&1 || true
      # The helper IS the new updater: pull and verify it here, then run exactly what was pulled.
      if pull_verified "$UPDATER_REPO:$UPDATER_UPDATE" "$UPDATER_UPDATE_DIGEST"; then
        docker run -d --rm --name "$HELPER" \
          -v /var/run/docker.sock:/var/run/docker.sock \
          -e ARGUS_UPDATER_MODE=probe-recreate \
          -e ARGUS_RECREATE_TARGET="$SELF" \
          -e ARGUS_RECREATE_TAG="$UPDATER_UPDATE" \
          -e ARGUS_RECREATE_DIGEST="$UPDATER_UPDATE_DIGEST" \
          "$UPDATER_REPO:$UPDATER_UPDATE" >/dev/null 2>&1 \
          || log "could not spawn $HELPER (check: docker logs $HELPER)"
      else
        log "updater self-update refused: $PULL_ERR"
      fi
    fi

    NAME=$(resolve_proxy || true)
    if [ -z "$NAME" ]; then
      log "no proxy container found yet (looked for '${PROXY_CONTAINER:-any}' / image $PROBE_IMAGE) - will retry"
    else
      CUR_IMAGE=$(api GET "/containers/$NAME/json" | jq -r '.Config.Image // empty')
      REPO=$(image_repo "$CUR_IMAGE"); [ -z "$REPO" ] && REPO="$PROBE_IMAGE"
      CUR_TAG=$(image_tag "$CUR_IMAGE"); [ -z "$CUR_TAG" ] && CUR_TAG="latest"

      # A one-shot dashboard update forces a recreate (re-pull the tag, even :latest); otherwise
      # converge on the fleet target only when its tag differs from the running one.
      DESIRED=""; FORCE=0; EXPECT=""
      if [ -n "$UPDATE" ]; then
        DESIRED="latest"; [ "$UPDATE" != "latest" ] && DESIRED="$UPDATE"; FORCE=1; EXPECT="$UPDATE_DIGEST"
      elif [ -n "$TARGET" ]; then
        DESIRED="latest"; [ "$TARGET" != "latest" ] && DESIRED="$TARGET"; EXPECT="$TARGET_DIGEST"
      fi

      if [ -n "$DESIRED" ] && { [ "$FORCE" = "1" ] || [ "$DESIRED" != "$CUR_TAG" ]; }; then
        log "converging $NAME: $CUR_TAG -> $DESIRED (force=$FORCE)"
        if recreate_container "$NAME" "$REPO:$DESIRED" "$EXPECT"; then
          log "$NAME updated to $REPO:$DESIRED"
        else
          log "update failed: $RECREATE_ERR" >&2
        fi
      fi
    fi
  fi

  sleep "$INTERVAL"
done
