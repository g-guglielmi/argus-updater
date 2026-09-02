# shellcheck shell=sh
# argus-updater shared recreate engine.
#
# The one copy of "recreate a container on a new image via the Docker Engine API" used by every mode
# (the core watcher, the probe one-shot recreate). It clones the running container's config
# (Binds/Mounts, env, restart policy, network, labels, ports) and swaps ONLY the image tag, so
# whatever flags the operator deployed with survive an update.
#
# Safety: the old container is stopped and renamed (not removed) first, and restored if the new one
# fails to create, start, OR stay up (a crash-looping bad image is rolled back too) - so a bad
# pull/create/build never leaves you without the target running.
#
# The caller must define two hooks before calling recreate_container:
#   progress MSG   - report an in-progress step (core -> status.json; probe -> stdout)
#   log MSG        - a plain log line
# and may set:
#   RECREATE_NOUN        - human noun for messages (default "container"); e.g. "core"
#   ARGUS_VERIFY_HEALTHZ - "1" to also accept a passing HTTP /healthz as healthy (core); else
#                          stability-only (an active Zabbix proxy has no HTTP endpoint to probe)
#   ARGUS_HEALTH_STABLE  - seconds the new container must stay up to pass (default 20)
#   ARGUS_VERIFY_TIMEOUT - give up (and roll back) after this long (default 90)
#
# recreate_container NAME NEW_IMAGE -> 0 on success; 1 on failure with RECREATE_ERR set to the
# reason (already rolled back to the previous container).

SOCK=/var/run/docker.sock
RECREATE_NOUN="${RECREATE_NOUN:-container}"
HEALTH_STABLE="${ARGUS_HEALTH_STABLE:-20}"
VERIFY_TIMEOUT="${ARGUS_VERIFY_TIMEOUT:-90}"

# api METHOD PATH [BODY] - talk to the Docker Engine API over the unix socket.
api() {
  if [ "$#" -ge 3 ]; then
    curl -sS --unix-socket "$SOCK" -X "$1" -H 'Content-Type: application/json' -d "$3" "http://localhost$2"
  else
    curl -sS --unix-socket "$SOCK" -X "$1" "http://localhost$2"
  fi
}

# self_container_id - THIS container's own id, resolved robustly. /etc/hostname is NOT reliable (it
# can be a custom hostname, or inherited from another container when a network namespace is shared).
# Docker bind-mounts this container's config files (hostname/hosts/resolv.conf) from
# /var/lib/docker/containers/<full-id>/... , so that id is visible in /proc/self/mountinfo regardless
# of the hostname. Fall back to /etc/hostname only if that fails.
self_container_id() {
  _cid=$(grep -oE 'containers/[0-9a-f]{64}' /proc/self/mountinfo 2>/dev/null | head -n1 | grep -oE '[0-9a-f]{64}')
  [ -z "$_cid" ] && _cid=$(cat /etc/hostname 2>/dev/null)
  printf '%s' "$_cid"
}

# image_repo IMAGE - strip the tag, keep the repo (ghcr.io/x/y:tag -> ghcr.io/x/y).
image_repo() { printf '%s' "$1" | sed 's/:[^:/]*$//'; }
# image_tag IMAGE - the tag (ghcr.io/x/y:tag -> tag; empty if none).
image_tag()  { printf '%s' "$1" | sed -n 's#.*:\([^:/]*\)$#\1#p'; }

# verify NAME - return 0 once the container looks healthy: it stays Running and not Restarting for
# HEALTH_STABLE seconds (a crash-loop guard - a bad image that starts then exits never reaches a
# stable window). When ARGUS_VERIFY_HEALTHZ=1 and the container has an IP on a shared network, a
# passing GET :8080/healthz short-circuits to healthy. Return 1 on timeout.
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
    if [ "${ARGUS_VERIFY_HEALTHZ:-0}" = "1" ]; then
      _ip=$(printf '%s' "$_json" | jq -r '[.NetworkSettings.Networks[]?.IPAddress] | map(select(. != "" and . != null)) | .[0] // empty')
      if [ -n "$_ip" ] && curl -sf -m 3 "http://$_ip:8080/healthz" >/dev/null 2>&1; then
        return 0
      fi
    fi
    _stable=$(( _stable + 1 ))
    [ "$_stable" -ge "$_need" ] && return 0
    sleep 3
  done
  return 1
}

# recreate_container NAME NEW_IMAGE - the full pull -> clone-config recreate -> verify -> rollback
# dance. Returns 0 on success, or 1 with RECREATE_ERR set (and the previous container restored).
recreate_container() {
  NAME="$1"; NEW_IMAGE="$2"
  RECREATE_ERR=""

  INSPECT=$(api GET "/containers/$NAME/json")
  CUR_IMAGE=$(printf '%s' "$INSPECT" | jq -r '.Config.Image // empty')
  if [ -z "$CUR_IMAGE" ]; then
    RECREATE_ERR="could not inspect the $RECREATE_NOUN container '$NAME'"
    return 1
  fi
  log "$NAME  $CUR_IMAGE -> $NEW_IMAGE"

  # Pull with a few retries: a transient registry/network blip must not silently no-op the update
  # (the pull happens BEFORE we touch the container, so a failure here leaves it running untouched).
  progress "pulling $NEW_IMAGE"
  _pn=1
  until docker pull "$NEW_IMAGE"; do
    if [ "$_pn" -ge 3 ]; then
      RECREATE_ERR="pull of $NEW_IMAGE failed after 3 attempts - the $RECREATE_NOUN was left untouched"
      log "pull failed after 3 attempts - the $RECREATE_NOUN untouched"
      return 1
    fi
    log "pull attempt $_pn failed; retrying in 5s"
    _pn=$(( _pn + 1 ))
    sleep 5
  done

  # Clone the config, swapping only the image. Keep operator-set Env/Labels/ExposedPorts and the
  # whole HostConfig (binds/mounts, restart policy, network, ports). Drop Cmd/Entrypoint/Hostname so
  # the NEW image's defaults apply and it gets a fresh hostname (= its own id).
  CREATE_BODY=$(printf '%s' "$INSPECT" | jq --arg img "$NEW_IMAGE" '{
    Image: $img,
    Env: .Config.Env,
    Labels: (.Config.Labels // {}),
    ExposedPorts: .Config.ExposedPorts,
    HostConfig: .HostConfig
  }')

  rollback() {
    log "rolling back to the previous $RECREATE_NOUN"
    api POST "/containers/${NAME}_old/rename?name=$NAME" >/dev/null 2>&1 || true
    api POST "/containers/$NAME/start" >/dev/null 2>&1 || true
  }

  progress "recreating $NAME on $NEW_IMAGE"
  api POST "/containers/$NAME/stop?t=15" >/dev/null 2>&1 || true
  if ! api POST "/containers/$NAME/rename?name=${NAME}_old" >/dev/null 2>&1; then
    api POST "/containers/$NAME/start" >/dev/null 2>&1 || true
    RECREATE_ERR="could not rename the old $RECREATE_NOUN - aborted, $RECREATE_NOUN left running"
    return 1
  fi

  NEWID=$(api POST "/containers/create?name=$NAME" "$CREATE_BODY" | jq -r '.Id // empty')
  if [ -z "$NEWID" ]; then
    rollback
    RECREATE_ERR="could not create the new $RECREATE_NOUN container - rolled back"
    return 1
  fi
  if ! api POST "/containers/$NEWID/start" >/dev/null 2>&1; then
    api DELETE "/containers/$NEWID?force=true" >/dev/null 2>&1 || true
    rollback
    RECREATE_ERR="the new $RECREATE_NOUN failed to start - rolled back"
    return 1
  fi

  progress "verifying the new $RECREATE_NOUN is healthy"
  if ! verify "$NAME"; then
    api POST "/containers/$NAME/stop?t=10" >/dev/null 2>&1 || true
    api DELETE "/containers/$NAME?force=true" >/dev/null 2>&1 || true
    rollback
    RECREATE_ERR="the new $RECREATE_NOUN did not become healthy in time - rolled back to the previous version"
    log "verify failed - rolled back"
    return 1
  fi

  # Success - drop the old container.
  api DELETE "/containers/${NAME}_old?force=true" >/dev/null 2>&1 || true
  log "$NAME updated to $NEW_IMAGE"
  return 0
}
