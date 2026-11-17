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
# It also restarts the proxy (no recreate) when Argus asks for it with {"restart_proxy":true}: the
# proxy reads its Zabbix process counts only at start, and Argus sizes them from the probe's load.
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
# The probe VM's host side (the OS reporter, the console menu, their units) rides the probe image;
# after each probe update we run that image once against the host (lib/hosttools.sh, probe role).
# Our mount of the proxy's data folder is read-only, so the outcome also rides our check-in.
HT_ROLE=probe
PROBE_DIR="${ARGUS_PROBE_DIR:-/probe}"
. "$LIBDIR/lib/hosttools.sh"
# The host's LAN address for the Probes page (lib/hostaddr.sh): read when we start and after each
# start of the proxy, and carried by every check-in.
. "$LIBDIR/lib/hostaddr.sh"
# Why the last update didn't take (lib/result.sh): Argus shows it on the Updates page, where until
# now a refusal read only as "still on the old version" twenty minutes later.
. "$LIBDIR/lib/result.sh"

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

# collect_selfupdate - what became of our own update. The helper that swaps us (probe-recreate, see
# below) stays behind when it ends, so that whoever runs next, the new sidecar or we again after a
# rollback, can read how it went: a helper that failed gives its last line as the reason, and either
# way it is removed. Sets HELPER_RUNNING=1 while it still works (it watches the new sidecar a while).
HELPER_SEEN=""
collect_selfupdate() {
  HELPER_RUNNING=0
  _cs=$(api GET "/containers/$(self_container_id)/json" 2>/dev/null | jq -r '.Name // empty' 2>/dev/null | sed 's#^/##')
  [ -n "$_cs" ] || return 0
  _ch="${_cs}-selfupdate"
  _cj=$(api GET "/containers/$_ch/json" 2>/dev/null || true)
  _cid=$(printf '%s' "$_cj" | jq -r '.Id // empty' 2>/dev/null || true)
  [ -n "$_cid" ] || return 0
  case "$(printf '%s' "$_cj" | jq -r '.State.Status // empty' 2>/dev/null)" in
    exited|dead) ;;
    *) HELPER_RUNNING=1; return 0 ;;
  esac
  _cec=$(printf '%s' "$_cj" | jq -r '.State.ExitCode // 0' 2>/dev/null || echo 0)
  if [ "$_cec" != "0" ] && [ "$_cid" != "$HELPER_SEEN" ]; then
    _ctag=$(printf '%s' "$_cj" | jq -r '[.Config.Env[]? | select(startswith("ARGUS_RECREATE_TAG=")) | sub("^ARGUS_RECREATE_TAG="; "")] | .[0] // "latest"' 2>/dev/null || echo latest)
    _cwhy=$(api GET "/containers/$_ch/logs?stdout=1&stderr=1&tail=80" 2>/dev/null | log_last_line false | sed 's/^argus-updater[^:]*: //' || true)
    [ -n "$_cwhy" ] || _cwhy="the helper that swaps the sidecar ended with exit code $_cec"
    log "our own update to $_ctag didn't take: $_cwhy"
    result_set updater "$_ctag" "$_cwhy" again
  fi
  HELPER_SEEN="$_cid"
  api DELETE "/containers/$_ch?force=true" >/dev/null 2>&1 || true
}

log "starting (poll ${INTERVAL}s, proxy=${PROXY_CONTAINER:-<by image $PROBE_IMAGE>})"
WAIT="$INTERVAL"
MISSED=0   # check-ins in a row that got no answer from Argus
while true; do
  heartbeat $((INTERVAL * 2 + 1800))   # a round may include a proxy recreate
  SOON=0   # an update just failed, or our own is still being watched: the next round comes soon
  collect_selfupdate
  [ "$HELPER_RUNNING" = "1" ] && SOON=1
  # A swap of the proxy that never ended (a power cut in the middle, or we were stopped): put the
  # proxy back and tell Argus. The update is tried again further down, like any other.
  swap_heal
  if [ "$HEALED" = "1" ]; then
    if [ "$HEAL_BACK" = "1" ]; then
      result_set probe "$(image_tag "$HEAL_TO")" "$HEAL_MSG" again
    else
      result_set probe "$(image_tag "$HEAL_TO")" "$HEAL_MSG"
    fi
    SOON=1
  fi
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
    host_lan "$(resolve_proxy 2>/dev/null || true)"
    # Advertise capability + report OUR (updater) version + read the target/one-shots. We report no
    # proxy version (the proxy reports its own); updater_version is our sidecar's own version.
    RESP=$(curl -sS -m 15 -H "Authorization: Bearer $PROBE_TOKEN" -H 'Content-Type: application/json' \
      -d "$(jq -nc --arg uv "$UPDATER_VERSION" --argjson ht "$(ht_report)" --argjson hl "$(ha_report)" --argjson ur "$(result_report)" '{selfupdate:true, updater_version:$uv, restarts:true, host_tools:$ht, host_lan:$hl, update_result:$ur}')" \
      "$CHECKIN_URL" 2>/dev/null || echo '')
    # Argus asks for the next round sooner while its Updates page is open or an update waits for us.
    # No answer at all (Argus restarting, the network gone): try again soon, backing off to the round.
    if answered "$RESP"; then
      MISSED=0
      WAIT=$(round_wait "$RESP" "$INTERVAL")
    else
      MISSED=$((MISSED + 1))
      WAIT=$(missed_wait "$MISSED" "$INTERVAL")
    fi
    TARGET=$(echo "$RESP" | jq -r '.target // empty' 2>/dev/null || true)
    UPDATE=$(echo "$RESP" | jq -r '.update // empty' 2>/dev/null || true)
    UPDATER_UPDATE=$(echo "$RESP" | jq -r '.updater_update // empty' 2>/dev/null || true)
    # A one-shot restart of the proxy, so it starts with the process counts Argus now wants.
    RESTART_PROXY=$(echo "$RESP" | jq -r 'if .restart_proxy == true then "yes" else "" end' 2>/dev/null || true)
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

    # Self-update: recreate OURSELVES via a short-lived copy running probe-recreate against our
    # own container (we can't rm -f ourselves). The ephemeral helper uses the NEW updater image so it
    # carries the latest recreate logic; it clones our config (mode, mounts, socket) onto the new tag.
    if [ -n "$UPDATER_UPDATE" ]; then
      SELF=$(self_container_id)
      # Name the helper (so `docker logs <name>` reaches it) and leave it behind when it ends: the
      # next round, ours after a rollback or the new sidecar's, reads how it went and removes it
      # (collect_selfupdate). It runs exactly the image pulled and verified here.
      _sn=$(api GET "/containers/$SELF/json" 2>/dev/null | jq -r '.Name // empty' 2>/dev/null | sed 's#^/##')
      [ -z "$_sn" ] && _sn="argus-updater"
      HELPER="${_sn}-selfupdate"
      log "updater self-update to $UPDATER_UPDATE requested - spawning $HELPER (target $SELF)"
      docker rm -f "$HELPER" >/dev/null 2>&1 || true
      # The helper IS the new updater: pull and verify it here, then run exactly what was pulled.
      if pull_verified "$UPDATER_REPO:$UPDATER_UPDATE" "$UPDATER_UPDATE_DIGEST"; then
        docker run -d --name "$HELPER" \
          -v /var/run/docker.sock:/var/run/docker.sock \
          -e ARGUS_UPDATER_MODE=probe-recreate \
          -e ARGUS_RECREATE_TARGET="$SELF" \
          -e ARGUS_RECREATE_TAG="$UPDATER_UPDATE" -e ARGUS_RECREATE_NOUN=sidecar \
          -e ARGUS_RECREATE_DIGEST="$UPDATER_UPDATE_DIGEST" \
          "$UPDATER_REPO:$UPDATER_UPDATE" >/dev/null 2>&1 \
          || { log "could not spawn $HELPER (check: docker logs $HELPER)"
               result_set updater "$UPDATER_UPDATE" "the sidecar could not start the helper that swaps it; nothing changed" again; SOON=1; }
      else
        log "updater self-update refused: $PULL_ERR"
        result_set updater "$UPDATER_UPDATE" "$PULL_ERR - the sidecar was left untouched" again
        SOON=1
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

      RECREATED=0
      if [ -n "$DESIRED" ] && { [ "$FORCE" = "1" ] || [ "$DESIRED" != "$CUR_TAG" ]; }; then
        log "converging $NAME: $CUR_TAG -> $DESIRED (force=$FORCE)"
        if recreate_container "$NAME" "$REPO:$DESIRED" "$EXPECT"; then
          log "$NAME updated to $REPO:$DESIRED"
          RECREATED=1
          result_clear probe
        else
          log "update failed: $RECREATE_ERR" >&2
          # An Update click is told each time it fails; the fleet target, retried every round, once
          # per reason.
          if [ "$FORCE" = "1" ]; then result_set probe "$DESIRED" "$RECREATE_ERR" again; else result_set probe "$DESIRED" "$RECREATE_ERR"; fi
          SOON=1
        fi
      fi
      # A recreated proxy has just started, and so already runs the counts Argus wants.
      if [ -n "$RESTART_PROXY" ] && [ "$RECREATED" = "0" ]; then
        log "restarting $NAME: Argus changed its Zabbix process counts"
        # The Engine API answers 204 with no body on success, a JSON message otherwise.
        _out=$(api POST "/containers/$NAME/restart?t=30" 2>&1 || true)
        if [ -z "$_out" ]; then
          log "$NAME restarted"
        else
          log "restart of $NAME failed: $(printf '%s' "$_out" | jq -r '.message // .' 2>/dev/null || printf '%s' "$_out")" >&2
        fi
      fi
    fi
  fi

  # The host's scripts and units, from the running probe image: after an update, daily, or ten
  # minutes after a failure (a container probe elsewhere is skipped once per image). When they were
  # just installed, the next round goes now: its check-in reports them, so the Updates page doesn't
  # show them "updating" for a whole interval after they went in.
  sync_host_tools
  if [ "$HT_RAN" = "1" ]; then continue; fi
  if [ "$SOON" = "1" ] && [ "$WAIT" -gt 15 ]; then WAIT=15; fi
  sleep "$WAIT"
done
