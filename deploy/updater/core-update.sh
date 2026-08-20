#!/bin/sh
# argus-updater: perform Argus core self-updates on the core's behalf.
#
# The public-facing core is distroless, non-root, and has NO Docker socket, so it cannot recreate
# itself. This sidecar holds the socket instead. It watches a directory shared with the core
# (ARGUS_UPDATE_DIR, default /update) for a request the core drops when an admin clicks "Update now":
#
#   request.json (core writes) -> {id, tag, from, requested_by, requested_at, core_container}
#   status.json  (we write)    -> {id, state:"running|success|failed", from, to, message, started_at, finished_at}
#
# For each new request it: pulls the target image; recreates the core container cloning its config
# (Binds/Mounts, env, restart policy, network, labels, ports) and swapping only the image tag; verifies
# the new container stays up (and, if reachable, that /healthz answers); rolls back to the previous
# container on any failure. The outcome + reason go back in status.json for the core's banner.
#
# Safety mirrors the probe's argus-recreate.sh: the old container is stopped and renamed (not removed)
# first and restored if the new one fails, so a bad pull/build never leaves you without a core.
set -eu

SOCK=/var/run/docker.sock
UPDATE_DIR="${ARGUS_UPDATE_DIR:-/update}"
REQUEST="$UPDATE_DIR/request.json"
STATUS="$UPDATE_DIR/status.json"
CORE_CONTAINER="${ARGUS_CORE_CONTAINER:-argus}"
CORE_IMAGE="${ARGUS_CORE_IMAGE:-ghcr.io/g-guglielmi/argus}"
INTERVAL="${ARGUS_UPDATE_INTERVAL:-10}"
HEALTH_STABLE="${ARGUS_HEALTH_STABLE:-20}"   # seconds the new core must stay up to pass
VERIFY_TIMEOUT="${ARGUS_VERIFY_TIMEOUT:-90}" # give up (and roll back) after this long

now()  { date -u +%Y-%m-%dT%H:%M:%SZ; }
log()  { echo "argus-updater: $*"; }

# api METHOD PATH [BODY] - talk to the Docker Engine API over the unix socket.
api() {
  if [ "$#" -ge 3 ]; then
    curl -sS --unix-socket "$SOCK" -X "$1" -H 'Content-Type: application/json' -d "$3" "http://localhost$2"
  else
    curl -sS --unix-socket "$SOCK" -X "$1" "http://localhost$2"
  fi
}

# write_status STATE MESSAGE [FINISHED_AT] - atomic (tmp + mv) so the core never reads a partial file.
write_status() {
  _state="$1"; _msg="$2"; _fin="${3:-}"
  jq -nc --arg id "$ID" --arg s "$_state" --arg from "$FROM" --arg to "$TAG" \
     --arg msg "$_msg" --arg started "$STARTED_AT" --arg fin "$_fin" \
     '{id:$id, state:$s, from:$from, to:$to, message:$msg, started_at:$started}
      + (if $fin == "" then {} else {finished_at:$fin} end)' \
     > "$STATUS.tmp" && mv "$STATUS.tmp" "$STATUS"
}

# resolve_core - echo the core container name to recreate: the configured name if it exists, else the
# first running container whose image repo matches CORE_IMAGE. Empty if none found.
resolve_core() {
  if api GET "/containers/$CORE_CONTAINER/json" | jq -e '.Id' >/dev/null 2>&1; then
    echo "$CORE_CONTAINER"; return 0
  fi
  api GET "/containers/json" \
    | jq -r --arg repo "$CORE_IMAGE" '.[] | select((.Image | split(":")[0]) == $repo) | .Names[0] // empty' \
    | sed 's#^/##' | head -n1
}

# verify NAME - return 0 once the container looks healthy: /healthz answers (if reachable on a shared
# network) OR it stays Running and not Restarting for HEALTH_STABLE seconds. Return 1 on timeout /
# crash loop. Socket-only friendly: the healthz probe is a bonus, the stability check always works.
verify() {
  _name="$1"
  sleep 5   # brief grace for startup
  _need=$(( HEALTH_STABLE / 3 )); [ "$_need" -lt 1 ] && _need=1
  _stable=0
  _end=$(( $(date +%s) + VERIFY_TIMEOUT ))
  while [ "$(date +%s)" -lt "$_end" ]; do
    _json=$(api GET "/containers/$_name/json")
    _running=$(printf '%s' "$_json" | jq -r '.State.Running // false')
    _restarting=$(printf '%s' "$_json" | jq -r '.State.Restarting // false')
    if [ "$_running" != "true" ] || [ "$_restarting" = "true" ]; then
      _stable=0; sleep 3; continue
    fi
    _ip=$(printf '%s' "$_json" | jq -r '[.NetworkSettings.Networks[]?.IPAddress] | map(select(. != "" and . != null)) | .[0] // empty')
    if [ -n "$_ip" ] && curl -sf -m 3 "http://$_ip:8080/healthz" >/dev/null 2>&1; then
      return 0
    fi
    _stable=$(( _stable + 1 ))
    [ "$_stable" -ge "$_need" ] && return 0
    sleep 3
  done
  return 1
}

# do_update - run one update job end to end, writing status as it goes.
do_update() {
  STARTED_AT=$(now)
  write_status running "starting update to $TAG"

  NAME=$(resolve_core || true)
  if [ -z "$NAME" ]; then
    write_status failed "could not find the core container (looked for '$CORE_CONTAINER' / image $CORE_IMAGE)" "$(now)"
    log "no core container found - aborting"
    return
  fi

  INSPECT=$(api GET "/containers/$NAME/json")
  CUR_IMAGE=$(printf '%s' "$INSPECT" | jq -r '.Config.Image // empty')
  if [ -z "$CUR_IMAGE" ]; then
    write_status failed "could not inspect the core container '$NAME'" "$(now)"
    return
  fi
  REPO=$(printf '%s' "$CUR_IMAGE" | sed 's/:[^:/]*$//')   # strip the tag, keep the repo
  # Two modes:
  #  - EXACT=true (a deliberate channel/version switch from the GUI): converge on the requested TAG
  #    verbatim, so the operator can move latest <-> testing <-> a pinned vX.Y.Z on purpose.
  #  - otherwise (a plain in-place update): preserve the core's release CHANNEL. A rolling tag
  #    (:latest / :testing) is re-pulled in place so it keeps tracking the channel (the pull gets the
  #    newer image); only a genuinely pinned version is bumped to the requested release. This keeps
  #    the latest/testing model intact instead of accidentally dropping a channel onto a fixed version.
  if [ "$EXACT" = "true" ]; then
    TARGET_TAG="$TAG"
  else
    CUR_TAG=$(printf '%s' "$CUR_IMAGE" | sed -n 's#.*:\([^:/]*\)$#\1#p')
    [ -z "$CUR_TAG" ] && CUR_TAG="latest"
    case "$CUR_TAG" in
      latest|testing) TARGET_TAG="$CUR_TAG" ;;
      *)              TARGET_TAG="$TAG" ;;
    esac
  fi
  NEW_IMAGE="$REPO:$TARGET_TAG"
  log "$NAME  $CUR_IMAGE -> $NEW_IMAGE (target version $TAG)"

  write_status running "pulling $NEW_IMAGE"
  if ! docker pull "$NEW_IMAGE"; then
    write_status failed "pull of $NEW_IMAGE failed - the core was left untouched" "$(now)"
    log "pull failed - core untouched"
    return
  fi

  # Clone the core's config, swapping only the image. Keep operator-set Env/Labels/ExposedPorts and
  # the whole HostConfig (binds/mounts incl. the shared update volume, restart policy, network, ports).
  # Drop Cmd/Entrypoint/Hostname so the NEW image's defaults apply and it gets a fresh hostname.
  CREATE_BODY=$(printf '%s' "$INSPECT" | jq --arg img "$NEW_IMAGE" '{
    Image: $img,
    Env: .Config.Env,
    Labels: (.Config.Labels // {}),
    ExposedPorts: .Config.ExposedPorts,
    HostConfig: .HostConfig
  }')

  rollback() {
    log "rolling back to the previous core"
    api POST "/containers/${NAME}_old/rename?name=$NAME" >/dev/null 2>&1 || true
    api POST "/containers/$NAME/start" >/dev/null 2>&1 || true
  }

  write_status running "recreating $NAME on $TAG"
  api POST "/containers/$NAME/stop?t=15" >/dev/null 2>&1 || true
  if ! api POST "/containers/$NAME/rename?name=${NAME}_old" >/dev/null 2>&1; then
    api POST "/containers/$NAME/start" >/dev/null 2>&1 || true
    write_status failed "could not rename the old core - aborted, core left running" "$(now)"
    return
  fi

  NEWID=$(api POST "/containers/create?name=$NAME" "$CREATE_BODY" | jq -r '.Id // empty')
  if [ -z "$NEWID" ]; then
    rollback
    write_status failed "could not create the new core container - rolled back" "$(now)"
    return
  fi
  if ! api POST "/containers/$NEWID/start" >/dev/null 2>&1; then
    api DELETE "/containers/$NEWID?force=true" >/dev/null 2>&1 || true
    rollback
    write_status failed "the new core failed to start - rolled back" "$(now)"
    return
  fi

  write_status running "verifying the new core is healthy"
  if ! verify "$NAME"; then
    api POST "/containers/$NAME/stop?t=10" >/dev/null 2>&1 || true
    api DELETE "/containers/$NAME?force=true" >/dev/null 2>&1 || true
    rollback
    write_status failed "the new core did not become healthy in time - rolled back to the previous version" "$(now)"
    log "verify failed - rolled back"
    return
  fi

  # Success - drop the old container.
  api DELETE "/containers/${NAME}_old?force=true" >/dev/null 2>&1 || true
  write_status success "updated to $TAG" "$(now)"
  log "$NAME updated to $NEW_IMAGE"
}

# The non-root, distroless core creates request.json in this shared dir, but a fresh Docker named
# volume mounts root-owned 0755 - which the core cannot write, so it could never queue (or dismiss)
# an update. We hold the socket and run as root, so make the channel writable by the core here.
# Self-heals existing volumes on restart; the dir only ever holds the tiny request/status JSON.
mkdir -p "$UPDATE_DIR"
chmod 0777 "$UPDATE_DIR" 2>/dev/null || log "warning: could not chmod $UPDATE_DIR (core may be unable to queue updates)"

log "watching $REQUEST (core=$CORE_CONTAINER, poll ${INTERVAL}s)"
LAST_ID=""
while true; do
  if [ -f "$REQUEST" ]; then
    ID=$(jq -r '.id // empty' "$REQUEST" 2>/dev/null || true)
    if [ -n "$ID" ] && [ "$ID" != "$LAST_ID" ]; then
      TAG=$(jq -r '.tag // empty' "$REQUEST" 2>/dev/null || true)
      FROM=$(jq -r '.from // empty' "$REQUEST" 2>/dev/null || true)
      EXACT=$(jq -r '.exact // false' "$REQUEST" 2>/dev/null || true)   # deliberate switch: use TAG verbatim
      # Guard against re-running a job we already finished (e.g. after a sidecar restart): if a status
      # for this id is already terminal, skip it.
      PRIOR_STATE=""
      if [ -f "$STATUS" ]; then
        PSID=$(jq -r '.id // empty' "$STATUS" 2>/dev/null || true)
        [ "$PSID" = "$ID" ] && PRIOR_STATE=$(jq -r '.state // empty' "$STATUS" 2>/dev/null || true)
      fi
      if [ "$PRIOR_STATE" = "success" ] || [ "$PRIOR_STATE" = "failed" ]; then
        LAST_ID="$ID"
      elif [ "$PRIOR_STATE" = "running" ]; then
        # We crashed mid-update; don't blindly re-run. Flag it so an admin can verify + retry.
        STARTED_AT=$(now)
        write_status failed "the updater restarted during an update; please verify the core version and retry" "$(now)"
        LAST_ID="$ID"
      elif [ -z "$TAG" ]; then
        log "request $ID has no tag - ignoring"
        LAST_ID="$ID"
      else
        log "update requested: $FROM -> $TAG (id $ID)"
        do_update
        LAST_ID="$ID"
      fi
    fi
  fi
  sleep "$INTERVAL"
done
