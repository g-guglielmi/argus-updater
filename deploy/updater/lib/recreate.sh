# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 g-guglielmi

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

  # Per-network endpoint settings (static IP, MAC, aliases) live under NetworkSettings.Networks, NOT
  # in HostConfig - so a plain HostConfig clone reconnects the container to its network but with an
  # auto-assigned IP/MAC and no aliases. Reconstruct them for the user-defined networks the container
  # is on. The default bridge / host / none modes carry no preservable endpoint config and fall
  # through to HostConfig.NetworkMode as before.
  NETMODE=$(printf '%s' "$INSPECT" | jq -r '.HostConfig.NetworkMode // "default"')
  USER_NETS=$(printf '%s' "$INSPECT" | jq -r '
    (.NetworkSettings.Networks // {}) | keys[]?
    | select(test("^(default|bridge|host|none)$") | not)')
  if printf '%s\n' "$USER_NETS" | grep -Fxq -- "$NETMODE"; then
    PRIMARY="$NETMODE"
  else
    PRIMARY=$(printf '%s\n' "$USER_NETS" | head -n1)
  fi

  # endpoint_cfg NET -> the create-time EndpointConfig for one network: only operator-set / stable
  # fields (static IP, MAC, aliases, links, driver opts), with runtime state (assigned IPAddress,
  # gateway, ids) stripped so Docker doesn't reject them.
  endpoint_cfg() {
    printf '%s' "$INSPECT" | jq --arg n "$1" '
      .NetworkSettings.Networks[$n] as $e
      | {
          IPAMConfig: ($e.IPAMConfig | if type == "object" then with_entries(select(.value != null and .value != "")) else null end),
          Aliases: $e.Aliases, MacAddress: $e.MacAddress, Links: $e.Links, DriverOpts: $e.DriverOpts
        }
      | with_entries(select(.value != null and .value != "" and .value != [] and .value != {}))'
  }

  # Clone the config, swapping only the image. Keep operator-set Env/Labels/ExposedPorts and the
  # whole HostConfig (binds/mounts, restart policy, network, ports). Preserve an operator-set
  # Hostname/Domainname and the primary network's endpoint (extra networks are connected after
  # create, below). Docker sets Hostname to the short id when the operator gave none - detect that
  # (== Id[0:12]) and drop it so the new container gets its own id, as the updater's self-update wants.
  NETCFG=null
  if [ -n "$PRIMARY" ]; then
    NETCFG=$(jq -n --arg n "$PRIMARY" --argjson ep "$(endpoint_cfg "$PRIMARY")" '{EndpointsConfig: {($n): $ep}}')
  fi
  CREATE_BODY=$(printf '%s' "$INSPECT" | jq --arg img "$NEW_IMAGE" --argjson net "$NETCFG" '
    {
      Image: $img,
      Env: .Config.Env,
      Labels: (.Config.Labels // {}),
      ExposedPorts: .Config.ExposedPorts,
      HostConfig: .HostConfig
    }
    + (if (.Config.Hostname // "") != "" and (.Config.Hostname != (.Id[0:12])) then {Hostname: .Config.Hostname} else {} end)
    + (if (.Config.Domainname // "") != "" then {Domainname: .Config.Domainname} else {} end)
    + (if $net != null then {NetworkingConfig: $net} else {} end)')

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

  # Attach any ADDITIONAL user networks (create only attached the primary), each with its own
  # preserved endpoint (static IP / MAC / aliases). Connect while still stopped so the container
  # starts already on every network. A failed connect rolls back rather than start half-networked.
  for _n in $USER_NETS; do
    [ "$_n" = "$PRIMARY" ] && continue
    _body=$(jq -n --arg c "$NEWID" --argjson ep "$(endpoint_cfg "$_n")" '{Container: $c, EndpointConfig: $ep}')
    _err=$(api POST "/networks/$_n/connect" "$_body" | jq -r '.message // empty')
    if [ -n "$_err" ]; then
      api DELETE "/containers/$NEWID?force=true" >/dev/null 2>&1 || true
      rollback
      RECREATE_ERR="could not attach the new $RECREATE_NOUN to network '$_n' ($_err) - rolled back"
      return 1
    fi
  done

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
