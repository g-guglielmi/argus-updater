# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 g-guglielmi

# shellcheck shell=sh
# argus-updater - mode: core (default).
#
# The public-facing core is distroless, non-root, and has NO Docker socket, so it cannot recreate
# itself. This mode holds the socket instead and watches a directory shared with the core
# (ARGUS_UPDATE_DIR, default /update) for a request the core drops when an admin clicks "Update now":
#
#   request.json    (core writes) -> {id, tag, from, requested_by, requested_at, exact}
#   status.json     (we write)    -> {id, state:"running|success|failed", from, to, message, ...}
#   core-image.json (we write)    -> {image, tag}  the tag the core runs under, so it knows its channel
#   updater-status.json (we + our swap helper write) -> a sidecar self-update, step by step
#   collectors.json (we write)    -> {state, message, version, installed, at}  the core host's
#                                    collectors, installed from the running core image (lib/collectors.sh)
#
# For each new request it pulls the target image and recreates the core via the shared engine
# (config-clone + verify + rollback), then writes the outcome back to status.json for the core banner.
set -eu

UPDATE_DIR="${ARGUS_UPDATE_DIR:-/update}"
REQUEST="$UPDATE_DIR/request.json"
STATUS="$UPDATE_DIR/status.json"
CORE_IMAGE_FILE="$UPDATE_DIR/core-image.json"
UPDATER_FILE="$UPDATE_DIR/updater.json"            # we report OUR (sidecar) version here
UPDATER_REQUEST="$UPDATE_DIR/updater-request.json"  # the core drops this to update US
SELF_STATUS="$UPDATE_DIR/updater-status.json"       # ...and reads that update's steps here
CORE_CONTAINER="${ARGUS_CORE_CONTAINER:-argus}"
CORE_IMAGE="${ARGUS_CORE_IMAGE:-ghcr.io/g-guglielmi/argus}"
UPDATER_REPO="${ARGUS_UPDATER_REPO:-ghcr.io/g-guglielmi/argus-updater}"
UPDATER_VERSION="$(cat /etc/argus-updater.version 2>/dev/null || echo dev)"
INTERVAL="${ARGUS_UPDATE_INTERVAL:-10}"

# The core host's collectors (its Zabbix server's external checks): sync_collectors.
# shellcheck source=/dev/null
. "$LIBDIR/lib/collectors.sh"

# The core is web-facing: accept a passing /healthz as proof of health, on top of stability.
export ARGUS_VERIFY_HEALTHZ=1
RECREATE_NOUN="core"

now() { date -u +%Y-%m-%dT%H:%M:%SZ; }
log() { echo "argus-updater[core]: $*"; }

# write_status STATE MESSAGE [FINISHED_AT] - atomic (tmp + mv) so the core never reads a partial file.
# Each new message is also kept as a step, so Settings shows the whole update, not just its last line.
STEPS='[]'; LAST_MSG=''
write_status() {
  _state="$1"; _msg="$2"; _fin="${3:-}"
  if [ -n "$_msg" ] && [ "$_msg" != "$LAST_MSG" ]; then
    STEPS=$(printf '%s' "$STEPS" | jq -c --arg at "$(now)" --arg m "$_msg" '. + [{at:$at, msg:$m}]' 2>/dev/null || printf '%s' "$STEPS")
    LAST_MSG="$_msg"
  fi
  jq -nc --arg id "$ID" --arg s "$_state" --arg from "$FROM" --arg to "$TAG" \
     --arg msg "$_msg" --arg started "$STARTED_AT" --arg fin "$_fin" --argjson steps "$STEPS" \
     '{id:$id, state:$s, from:$from, to:$to, message:$msg, started_at:$started, steps:$steps}
      + (if $fin == "" then {} else {finished_at:$fin} end)' \
     > "$STATUS.tmp" && mv "$STATUS.tmp" "$STATUS"
}

# progress MSG - the shared engine's in-progress hook: surface each step in status.json.
progress() { write_status running "$1"; }

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

# report_core_image - tell the core which image tag it runs under (written to the shared dir). This is
# the core's authoritative channel signal: a clean release image is byte-identical on :latest and
# :testing, so the core can't self-identify its channel right after a release - but we hold the socket
# and can read its Config.Image. Cheap (one inspect); refreshed every poll so it tracks the tag across
# a recreate/redeploy. Best-effort: any failure just leaves the last report in place.
report_core_image() {
  _name=$(resolve_core 2>/dev/null || true)
  [ -z "$_name" ] && return 0
  _img=$(api GET "/containers/$_name/json" 2>/dev/null | jq -r '.Config.Image // empty' 2>/dev/null || true)
  [ -z "$_img" ] && return 0
  _tag=$(image_tag "$_img"); [ -z "$_tag" ] && _tag="latest"
  jq -nc --arg img "$_img" --arg tag "$_tag" '{image:$img, tag:$tag}' \
     > "$CORE_IMAGE_FILE.tmp" 2>/dev/null && mv "$CORE_IMAGE_FILE.tmp" "$CORE_IMAGE_FILE" 2>/dev/null || true
}

# report_updater - tell the core our own (sidecar) version, so Settings can show it + offer an update.
report_updater() {
  jq -nc --arg v "$UPDATER_VERSION" '{version:$v}' \
     > "$UPDATER_FILE.tmp" 2>/dev/null && mv "$UPDATER_FILE.tmp" "$UPDATER_FILE" 2>/dev/null || true
}

# check_updater_request - the core drops updater-request.json to update the sidecar itself. We can't
# rm -f ourselves, so spawn an ephemeral --rm copy in probe-recreate mode targeting our own container.
# Consume the request BEFORE spawning so the recreated (new) sidecar never re-runs it. Every step goes
# to updater-status.json (the helper adds its own), so Settings follows the update to its end.
check_updater_request() {
  [ -f "$UPDATER_REQUEST" ] || return 0
  _uid=$(jq -r '.id // empty' "$UPDATER_REQUEST" 2>/dev/null || true)
  [ -z "$_uid" ] && { rm -f "$UPDATER_REQUEST"; return 0; }
  _utag=$(jq -r '.tag // "latest"' "$UPDATER_REQUEST" 2>/dev/null || echo latest)
  if ! valid_tag "$_utag"; then
    log "updater request $_uid carries an invalid tag - ignoring"; rm -f "$UPDATER_REQUEST"
    job_write "$SELF_STATUS" "$_uid" failed "the request names no valid version; the sidecar stays on $UPDATER_VERSION"
    return 0
  fi
  _udigest=$(jq -r '.digest // empty' "$UPDATER_REQUEST" 2>/dev/null || true)
  if [ -n "$_udigest" ] && ! valid_digest "$_udigest"; then log "updater request $_uid carries a malformed digest - ignoring it"; _udigest=""; fi
  _self=$(self_container_id)
  _selfjson=$(api GET "/containers/$_self/json" 2>/dev/null || true)
  # Name the helper (so `docker logs <name>` reaches it while it runs) but --rm it (auto-removed on
  # exit - no lingering container). --pull always so it runs the freshest image, never stale code.
  _sn=$(printf '%s' "$_selfjson" | jq -r '.Name // empty' 2>/dev/null | sed 's#^/##')
  [ -z "$_sn" ] && _sn="argus-updater"
  _helper="${_sn}-selfupdate"
  log "updater self-update to $_utag requested (id $_uid) - spawning $_helper (target $_self)"
  rm -f "$UPDATER_REQUEST"
  job_write "$SELF_STATUS" "$_uid" running "the sidecar ($UPDATER_VERSION) picked up the update to $_utag" \
    "$(jq -nc --arg f "$UPDATER_VERSION" --arg t "$_utag" '{from:$f, tag:$t}')"
  docker rm -f "$_helper" >/dev/null 2>&1 || true
  # The helper IS the new updater: pull and verify it here, then run exactly what was pulled.
  job_write "$SELF_STATUS" "$_uid" running "pulling $UPDATER_REPO:$_utag"
  if ! pull_verified "$UPDATER_REPO:$_utag" "$_udigest"; then
    log "updater self-update refused: $PULL_ERR"
    job_write "$SELF_STATUS" "$_uid" failed "$PULL_ERR; the sidecar stays on $UPDATER_VERSION"
    return 0
  fi
  _newid=$(docker image inspect --format '{{.Id}}' "$UPDATER_REPO:$_utag" 2>/dev/null || true)
  _newver=$(docker image inspect --format '{{index .Config.Labels "io.argus.updater.version"}}' "$UPDATER_REPO:$_utag" 2>/dev/null || true)
  case "$_newver" in ""|"<no value>") _newver="the new version" ;; esac
  _ownid=$(printf '%s' "$_selfjson" | jq -r '.Image // empty' 2>/dev/null || true)
  if [ -n "$_newid" ] && [ "$_newid" = "$_ownid" ]; then
    job_write "$SELF_STATUS" "$_uid" success "already on the newest sidecar ($UPDATER_VERSION): nothing to swap"
    return 0
  fi
  job_write "$SELF_STATUS" "$_uid" running "pulled $_newver; a helper swaps it in now (the sidecar restarts, the core keeps running)" \
    "$(jq -nc --arg to "$_newver" --arg img "$_newid" --arg h "$_helper" '{to:$to, to_image:$img, helper:$h}')"
  # The helper reports its steps into the same file: hand it the shared dir, where we have it mounted.
  _umount=$(printf '%s' "$_selfjson" | jq -r --arg d "$UPDATE_DIR" \
    'first(.Mounts[]? | select(.Destination == $d) | if .Type == "volume" then .Name else .Source end) // empty' 2>/dev/null || true)
  if [ -n "$_umount" ]; then
    _jobargs="-v $_umount:$UPDATE_DIR -e ARGUS_JOB_FILE=$SELF_STATUS -e ARGUS_JOB_ID=$_uid"
  else
    _jobargs=""
  fi
  # shellcheck disable=SC2086 # _jobargs is a list of options
  if ! docker run -d --rm --name "$_helper" \
      -v /var/run/docker.sock:/var/run/docker.sock $_jobargs \
      -e ARGUS_UPDATER_MODE=probe-recreate \
      -e ARGUS_RECREATE_TARGET="$_self" \
      -e ARGUS_RECREATE_TAG="$_utag" \
      -e ARGUS_RECREATE_DIGEST="$_udigest" \
      -e ARGUS_RECREATE_NOUN=sidecar \
      "$UPDATER_REPO:$_utag" >/dev/null 2>&1; then
    log "could not spawn $_helper (check: docker logs $_helper)"
    job_write "$SELF_STATUS" "$_uid" failed "could not start the helper that swaps the sidecar; it stays on $UPDATER_VERSION"
  fi
}

# check_self_update - settle a sidecar self-update its helper left open: while the helper runs it
# reports the outcome itself; once it is gone without a word, we either run the image it pulled (it
# died after the swap) or still the old one (the swap never happened, or rolled back silently).
check_self_update() {
  [ "$(job_get "$SELF_STATUS" state)" = running ] || return 0
  _to=$(job_get "$SELF_STATUS" to_image)
  [ -z "$_to" ] && return 0   # still pulling: the round that runs it judges it
  _h=$(job_get "$SELF_STATUS" helper)
  if [ -n "$_h" ] && api GET "/containers/$_h/json" 2>/dev/null | jq -e '.Id' >/dev/null 2>&1; then
    return 0
  fi
  _jid=$(job_get "$SELF_STATUS" id)
  _own=$(api GET "/containers/$(self_container_id)/json" 2>/dev/null | jq -r '.Image // empty' 2>/dev/null || true)
  [ -z "$_own" ] && return 0   # can't see ourselves: no verdict
  if [ "$_own" = "$_to" ]; then
    job_write "$SELF_STATUS" "$_jid" success "the new sidecar ($UPDATER_VERSION) is running"
  else
    job_write "$SELF_STATUS" "$_jid" failed "the swap didn't happen; the sidecar is still on $UPDATER_VERSION"
  fi
  return 0
}

# do_update - run one update job end to end, writing status as it goes.
do_update() {
  STARTED_AT=$(now); STEPS='[]'; LAST_MSG=''
  write_status running "starting update to $TAG"

  NAME=$(resolve_core || true)
  if [ -z "$NAME" ]; then
    write_status failed "could not find the core container (looked for '$CORE_CONTAINER' / image $CORE_IMAGE)" "$(now)"
    log "no core container found - aborting"
    return
  fi

  CUR_IMAGE=$(api GET "/containers/$NAME/json" | jq -r '.Config.Image // empty')
  if [ -z "$CUR_IMAGE" ]; then
    write_status failed "could not inspect the core container '$NAME'" "$(now)"
    return
  fi
  REPO=$(image_repo "$CUR_IMAGE")
  # Two modes:
  #  - EXACT=true (a deliberate channel/version switch from the GUI): converge on the requested TAG
  #    verbatim, so the operator can move latest <-> testing <-> a pinned vX.Y.Z on purpose.
  #  - otherwise (a plain in-place update): preserve the core's release CHANNEL. A rolling tag
  #    (:latest / :testing) is re-pulled in place so it keeps tracking the channel; only a genuinely
  #    pinned version is bumped to the requested release.
  if [ "$EXACT" = "true" ]; then
    TARGET_TAG="$TAG"
  else
    CUR_TAG=$(image_tag "$CUR_IMAGE"); [ -z "$CUR_TAG" ] && CUR_TAG="latest"
    case "$CUR_TAG" in
      latest|testing) TARGET_TAG="$CUR_TAG" ;;
      *)              TARGET_TAG="$TAG" ;;
    esac
  fi
  NEW_IMAGE="$REPO:$TARGET_TAG"
  # The digest the core saw this tag point to when it wrote the request (per tag, since the tag
  # pulled may be the preserved channel rather than the requested one).
  EXPECT=$(jq -r --arg t "$TARGET_TAG" '.digests[$t] // empty' "$REQUEST" 2>/dev/null || true)
  if [ -n "$EXPECT" ] && ! valid_digest "$EXPECT"; then log "request $ID carries a malformed digest for $TARGET_TAG - ignoring it"; EXPECT=""; fi
  log "target version $TAG -> image $NEW_IMAGE"

  if recreate_container "$NAME" "$NEW_IMAGE" "$EXPECT"; then
    write_status success "updated to $TAG" "$(now)"
  else
    write_status failed "$RECREATE_ERR" "$(now)"
  fi
}

# The non-root, distroless core (uid 65532) creates request.json in this shared dir, but a fresh
# Docker named volume mounts root-owned 0755 - which the core cannot write. We hold the socket and
# run as root, so hand the directory to the core here: owned by it, writable by it and by us, and
# by nobody else on the host (a request file here is an instruction to the socket holder).
# Self-heals existing volumes on restart.
mkdir -p "$UPDATE_DIR"
chown 65532:65532 "$UPDATE_DIR" 2>/dev/null || log "warning: could not chown $UPDATE_DIR (core may be unable to queue updates)"
chmod 0750 "$UPDATE_DIR" 2>/dev/null || log "warning: could not chmod $UPDATE_DIR"

log "watching $REQUEST (core=$CORE_CONTAINER, poll ${INTERVAL}s)"
report_core_image   # tell the core its running tag/channel right away, before the first poll
report_updater      # ...and our own sidecar version
check_self_update   # ...and how a self-update of ours ended, when we are its result
LAST_ID=""
while true; do
  heartbeat $((INTERVAL * 3 + 1800))   # a round may include a whole update
  report_core_image   # keep the core's channel signal current (tracks a recreate / redeploy)
  sync_collectors     # the core host's Zabbix runs the running image's collectors
  report_updater      # keep our reported sidecar version current
  check_updater_request   # act on a "update the sidecar" request from the core
  check_self_update       # settle one whose helper is gone
  if [ -f "$REQUEST" ]; then
    ID=$(jq -r '.id // empty' "$REQUEST" 2>/dev/null || true)
    if [ -n "$ID" ] && [ "$ID" != "$LAST_ID" ]; then
      TAG=$(jq -r '.tag // empty' "$REQUEST" 2>/dev/null || true)
      FROM=$(jq -r '.from // empty' "$REQUEST" 2>/dev/null || true)
      EXACT=$(jq -r '.exact // false' "$REQUEST" 2>/dev/null || true)   # deliberate switch: use TAG verbatim
      # Guard against re-running a job we already finished (e.g. after a restart): if a status for this
      # id is already terminal, skip it.
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
      elif [ -z "$TAG" ] || ! valid_tag "$TAG"; then
        log "request $ID has no usable tag - ignoring"
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
