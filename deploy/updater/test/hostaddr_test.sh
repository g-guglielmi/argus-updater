#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 g-guglielmi
#
# Test for lib/hostaddr.sh: when probe-watch reads the host's LAN address, what kind of network it
# says the proxy is on, and what it reports. Pure: api, docker and the clock are stubs; only jq.
set -u
DIR=$(cd "$(dirname "$0")/.." && pwd)
command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not installed"; exit 0; }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
# shellcheck source=/dev/null
. "$DIR/lib/hostaddr.sh"

# --- stubs ---
STARTED="2026-11-03T22:00:00Z"
MODE="bridge"
DRIVER="bridge"
ROUTE='1.1.1.1 via 10.0.1.1 dev eth0  src 10.0.1.20 '
DOCKER_RC=0
CLOCK=1000000
log() { :; }
epoch() { echo "$CLOCK"; }
self_container_id() { echo selfid; }
api() {
  case "$2" in
    /containers/argus-probe/json) printf '{"Id":"abc","State":{"StartedAt":"%s"},"HostConfig":{"NetworkMode":"%s"}}' "$STARTED" "$MODE" ;;
    /containers/selfid/json) echo '{"Image":"sha256:upd","Name":"/argus-probe-updater"}' ;;
    /networks/*) printf '{"Name":"%s","Driver":"%s"}' "${2#/networks/}" "$DRIVER" ;;
  esac
}
docker() {
  [ "$1" = run ] || return 0   # the rm -f of a leftover helper
  echo "$*" >> "$TMP/calls"; [ "$DOCKER_RC" = 0 ] && printf '%s\n' "$ROUTE"; return "$DOCKER_RC"
}

fail=0
calls() { [ -f "$TMP/calls" ] && wc -l < "$TMP/calls" | tr -d ' ' || echo 0; }
check() { # desc got want
  if [ "$2" = "$3" ]; then echo "  ok   $1"; else echo "  FAIL $1: got <$2> want <$3>"; fail=1; fi
}
r() { ha_report | jq -r "$1"; }

echo "nothing to report before a lookup"
check "null"          "$(ha_report)" null

echo "on Docker's bridge the first round reads the host's route, with our own image"
host_lan argus-probe
check "one run"       "$(calls)" 1
check "host network"  "$(grep -c -- '--network host' "$TMP/calls")" 1
check "our image"     "$(grep -c 'sha256:upd -4 route get 1.1.1.1' "$TMP/calls")" 1
check "named"         "$(grep -c -- '--name argus-probe-updater-addr' "$TMP/calls")" 1
check "net"           "$(r .net)" bridge
check "address"       "$(r .ip)" 10.0.1.20
check "gateway"       "$(r .gw)" 10.0.1.1

echo "the next rounds don't, while the probe runs on"
host_lan argus-probe; host_lan argus-probe
check "still one run" "$(calls)" 1

echo "a probe restart reads it again"
STARTED="2026-11-03T23:00:00Z"; ROUTE='1.1.1.1 dev eth0 src 10.0.1.21'
host_lan argus-probe
check "two runs"      "$(calls)" 2
check "new address"   "$(r .ip)" 10.0.1.21
check "no gateway"    "$(r .gw)" ""

echo "a failed read keeps the last address and tries again an hour later"
STARTED="2026-11-04T00:00:00Z"; DOCKER_RC=1
host_lan argus-probe
check "three runs"    "$(calls)" 3
check "kept"          "$(r .ip)" 10.0.1.21
host_lan argus-probe
check "not at once"   "$(calls)" 3
CLOCK=$((CLOCK + 3601)); DOCKER_RC=0; ROUTE='1.1.1.1 via 10.0.2.1 dev eth0 src 10.0.2.20'
host_lan argus-probe
check "an hour later" "$(calls)" 4
check "read"          "$(r .ip)" 10.0.2.20

echo "a user's own bridge network is read the same way"
STARTED="2026-11-04T01:00:00Z"; MODE="probes"; DRIVER="bridge"
host_lan argus-probe
check "five runs"     "$(calls)" 5
check "net"           "$(r .net)" bridge

echo "on a macvlan, an ipvlan or the host's network: no helper, the proxy's own address counts"
for m in macvlan ipvlan; do
  STARTED="2026-11-04T02:00:00Z-$m"; MODE="br0"; DRIVER="$m"
  host_lan argus-probe
  check "$m: no run"      "$(calls)" 5
  check "$m: net"         "$(r .net)" "$m"
  check "$m: no address"  "$(r 'has("ip")')" false
done
STARTED="2026-11-04T03:00:00Z"; MODE="host"
host_lan argus-probe
check "host: no run"      "$(calls)" 5
check "host: net"         "$(r .net)" host

echo "a network name that isn't one is not looked up, and the host's route is read"
STARTED="2026-11-04T04:00:00Z"; MODE='br0/../x'; DRIVER="macvlan"
host_lan argus-probe
check "read instead"      "$(calls)" 6
check "net unknown"       "$(r .net)" ""

echo "output without a source address reads as nothing"
check "no src"        "$(printf 'RTNETLINK answers: Network unreachable\n' | ha_parse)" ""
check "iproute2 form" "$(printf '1.1.1.1 via 10.0.3.1 dev ens18 src 10.0.3.5 uid 0 \n    cache \n' | ha_parse)" "10.0.3.5 10.0.3.1"

echo "no proxy container: nothing runs"
host_lan ""
check "still six"     "$(calls)" 6

exit $fail
