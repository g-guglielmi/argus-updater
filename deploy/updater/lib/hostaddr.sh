# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 g-guglielmi

# shellcheck shell=sh
# argus-updater - the probe host's LAN address (probe-watch mode).
#
# The Probes page shows each probe's LAN address (argus-core probeaddrs.go). A proxy container on
# Docker's bridge sees only its own 172.17.x address, and so do we. We hold the socket, so we run our
# own image once with the host's network and read the source address and the gateway of the host's
# route to the internet. A LAN address rarely changes while the host stays up, so this runs when we
# start (a host reboot or a move starts us too) and whenever the proxy container starts again (an
# update, a restart), not on a timer; after a failure, again an hour later. The result rides every
# check-in, so a lost one costs nothing.
#
# Needs from the caller: api, docker, log, self_container_id.

HA_FOR=""     # the proxy container start the last lookup was for ("<id>@<StartedAt>")
HA_DOC=""     # {"ip","gw"} from the last lookup that worked, "" before one did
HA_RETRY=0    # after a failed lookup, when to try again (epoch seconds); 0 when the last one worked
command -v epoch >/dev/null 2>&1 || epoch() { date +%s; }

# ha_parse - `ip -4 route get` output on stdin (busybox and iproute2 print it alike), {"ip","gw"} on
# stdout, or nothing when it names no source address.
ha_parse() {
  _l=$(awk '{ for (i = 1; i < NF; i++) { if ($i == "src" && s == "") s = $(i + 1); if ($i == "via" && g == "") g = $(i + 1) } }
            END { if (s != "") print s, g }')
  [ -n "$_l" ] || return 0
  # shellcheck disable=SC2086
  set -- $_l
  jq -nc --arg ip "$1" --arg gw "${2:-}" '{ip:$ip, gw:$gw}'
}

# host_lan NAME - look the host's LAN address up when the proxy container NAME started since the last
# lookup, or an hour after one that failed.
host_lan() {
  [ -n "$1" ] || return 0
  _for=$(api GET "/containers/$1/json" 2>/dev/null | jq -r '"\(.Id // "")@\(.State.StartedAt // "")"' 2>/dev/null || true)
  case "$_for" in ''|@*) return 0 ;; esac
  if [ "$_for" = "$HA_FOR" ] && { [ "$HA_RETRY" = 0 ] || [ "$(epoch)" -lt "$HA_RETRY" ]; }; then return 0; fi
  HA_FOR=$_for
  _self=$(api GET "/containers/$(self_container_id)/json" 2>/dev/null || true)
  _img=$(printf '%s' "$_self" | jq -r '.Image // empty' 2>/dev/null || true)
  _name=$(printf '%s' "$_self" | jq -r '.Name // empty' 2>/dev/null | sed 's#^/##')
  [ -n "$_name" ] || _name=argus-updater
  _doc=""
  if [ -n "$_img" ]; then
    # Our own image, so nothing is pulled; read-only, no capabilities, nobody: it only reads routes.
    # A helper a crash left behind would hold the name.
    docker rm -f "$_name-addr" >/dev/null 2>&1 || true
    _doc=$(docker run --rm --name "$_name-addr" --network host --read-only --cap-drop ALL --user 65534:65534 \
      --entrypoint ip "$_img" -4 route get 1.1.1.1 2>/dev/null | ha_parse || true)
  fi
  if [ -n "$_doc" ]; then
    HA_DOC=$_doc
    HA_RETRY=0
    log "host address: $(printf '%s' "$_doc" | jq -r '"\(.ip) (gateway \(if .gw == "" then "none" else .gw end))"' 2>/dev/null)"
  else
    HA_RETRY=$(( $(epoch) + 3600 ))
    log "host address: could not read the host's route to the internet; trying again in an hour"
  fi
}

# ha_report - the host's LAN address for the check-in body, or null before a lookup worked.
ha_report() { if [ -n "$HA_DOC" ]; then printf '%s' "$HA_DOC"; else printf 'null'; fi; }
