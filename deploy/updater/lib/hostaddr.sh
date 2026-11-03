# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 g-guglielmi

# shellcheck shell=sh
# argus-updater - the probe's LAN address (probe-watch mode).
#
# The Probes page shows each probe's LAN address (argus-core probeaddrs.go). We tell Argus which kind
# of Docker network the proxy container is on (`net`): on a macvlan or an ipvlan it has an address of
# its own on the LAN, and with host networking it has the host's, so the address it reports itself is
# the one to show and there is nothing more to read. On a bridge (Docker's own, or one of the user's)
# it sees only its own 172.x address, and so do we; we hold the socket, so we run our own image once
# with the host's network and read the source address and the gateway of the host's route to the
# internet. A LAN address rarely changes while the host stays up, so this runs when we start (a host
# reboot or a move starts us too) and whenever the proxy container starts again (an update, a
# restart), not on a timer; after a failed read, again an hour later. The result rides every
# check-in, so a lost one costs nothing.
#
# Needs from the caller: api, docker, log, self_container_id.

HA_FOR=""     # the proxy container start the last lookup was for ("<id>@<StartedAt>")
HA_DOC=""     # {"net"} or {"net","ip","gw"} from the last lookup that worked, "" before one did
HA_RETRY=0    # after a failed read, when to try again (epoch seconds); 0 when the last one worked
command -v epoch >/dev/null 2>&1 || epoch() { date +%s; }

# ha_parse - `ip -4 route get` output on stdin (busybox and iproute2 print it alike), "<src> <via>"
# on stdout, or nothing when it names no source address.
ha_parse() {
  awk '{ for (i = 1; i < NF; i++) { if ($i == "src" && s == "") s = $(i + 1); if ($i == "via" && g == "") g = $(i + 1) } }
       END { if (s != "") print s, g }'
}

# ha_net CONTAINER_JSON - the driver of the network the proxy container is on: host, bridge, macvlan,
# ipvlan, ... ("" when it can't be told: another container's namespace, an unreadable network).
ha_net() {
  _mode=$(printf '%s' "$1" | jq -r '.HostConfig.NetworkMode // empty' 2>/dev/null || true)
  case "$_mode" in
    host) echo host ;;
    bridge|default) echo bridge ;;
    ''|none|container:*) ;;
    *[!A-Za-z0-9_.-]*) ;;
    *) api GET "/networks/$_mode" 2>/dev/null | jq -r '.Driver // empty' 2>/dev/null | tr -d '\r' || true ;;
  esac
}

# host_lan NAME - after the proxy container NAME started (or an hour after a failed read): tell its
# network's kind and, on a bridge, read the host's LAN address.
host_lan() {
  [ -n "$1" ] || return 0
  _pj=$(api GET "/containers/$1/json" 2>/dev/null || true)
  _for=$(printf '%s' "$_pj" | jq -r '"\(.Id // "")@\(.State.StartedAt // "")"' 2>/dev/null || true)
  case "$_for" in ''|@*) return 0 ;; esac
  if [ "$_for" = "$HA_FOR" ] && { [ "$HA_RETRY" = 0 ] || [ "$(epoch)" -lt "$HA_RETRY" ]; }; then return 0; fi
  HA_FOR=$_for
  _net=$(ha_net "$_pj")
  case "$_net" in
    host|macvlan|ipvlan)
      # The proxy's own address is the LAN one: nothing to read.
      HA_DOC=$(jq -nc --arg n "$_net" '{net:$n}')
      HA_RETRY=0
      log "host address: the proxy is on a $_net network, its own address is the LAN one"
      return 0 ;;
  esac
  _self=$(api GET "/containers/$(self_container_id)/json" 2>/dev/null || true)
  _img=$(printf '%s' "$_self" | jq -r '.Image // empty' 2>/dev/null || true)
  _name=$(printf '%s' "$_self" | jq -r '.Name // empty' 2>/dev/null | sed 's#^/##')
  [ -n "$_name" ] || _name=argus-updater
  _route=""
  if [ -n "$_img" ]; then
    # Our own image, so nothing is pulled; read-only, no capabilities, nobody: it only reads routes.
    # A helper a crash left behind would hold the name.
    docker rm -f "$_name-addr" >/dev/null 2>&1 || true
    _route=$(docker run --rm --name "$_name-addr" --network host --read-only --cap-drop ALL --user 65534:65534 \
      --entrypoint ip "$_img" -4 route get 1.1.1.1 2>/dev/null | ha_parse || true)
  fi
  if [ -n "$_route" ]; then
    # shellcheck disable=SC2086
    set -- $_route
    HA_DOC=$(jq -nc --arg n "$_net" --arg ip "$1" --arg gw "${2:-}" '{net:$n, ip:$ip, gw:$gw}')
    HA_RETRY=0
    log "host address: $1 (gateway ${2:-none}; the proxy is on a ${_net:-unknown} network)"
  else
    HA_RETRY=$(( $(epoch) + 3600 ))
    log "host address: could not read the host's route to the internet; trying again in an hour"
  fi
}

# ha_report - the probe's network kind and the host's LAN address for the check-in body, or null
# before a lookup worked.
ha_report() { if [ -n "$HA_DOC" ]; then printf '%s' "$HA_DOC"; else printf 'null'; fi; }
