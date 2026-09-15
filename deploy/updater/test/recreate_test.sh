#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 g-guglielmi
#
# Regression test for lib/recreate.sh's config clone: an image swap must PRESERVE the network
# endpoint (static IP / MAC / aliases) and an operator-set hostname - these live in
# NetworkSettings.Networks / Config.Hostname, not HostConfig, and a plain HostConfig clone silently
# dropped them (rewriting custom-network deployments on every update). Pure: it feeds fixture
# `docker inspect` JSON to the extracted builder functions; no Docker daemon needed, only jq.
set -u
DIR=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck source=/dev/null
. "$DIR/lib/recreate.sh"   # defines user_nets / primary_net / endpoint_cfg / build_create_body

command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not installed"; exit 0; }

fail=0
NEW="ghcr.io/x/y:new"
ID="abcdef012345aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"  # Id[0:12] = abcdef012345

check() { # desc  jq-filter  expected   (against $BODY)
  got=$(printf '%s' "$BODY" | jq -c "$2")
  if [ "$got" = "$3" ]; then echo "  ok   $1"; else echo "  FAIL $1: got <$got> want <$3>"; fail=1; fi
}

echo "custom network: static IP + MAC + alias + operator hostname all preserved"
BODY=$(build_create_body "$NEW" '{"Id":"'"$ID"'","Config":{"Hostname":"myhost","Domainname":"lan","Env":["A=1"],"Labels":{"k":"v"},"ExposedPorts":{"80/tcp":{}}},"HostConfig":{"NetworkMode":"mynet","Binds":["/a:/b"]},"NetworkSettings":{"Networks":{"mynet":{"IPAMConfig":{"IPv4Address":"10.7.0.50"},"Aliases":["svc"],"MacAddress":"02:42:0a:07:00:32","IPAddress":"10.7.0.50","Gateway":"10.7.0.1","NetworkID":"n","EndpointID":"e","Links":null,"DriverOpts":null}}}}')
check "image swapped"        '.Image' '"ghcr.io/x/y:new"'
check "hostname preserved"   '.Hostname' '"myhost"'
check "domainname preserved" '.Domainname' '"lan"'
check "static IP preserved"  '.NetworkingConfig.EndpointsConfig.mynet.IPAMConfig.IPv4Address' '"10.7.0.50"'
check "MAC preserved"        '.NetworkingConfig.EndpointsConfig.mynet.MacAddress' '"02:42:0a:07:00:32"'
check "alias preserved"      '.NetworkingConfig.EndpointsConfig.mynet.Aliases' '["svc"]'
check "runtime IP stripped"  '.NetworkingConfig.EndpointsConfig.mynet | has("IPAddress")' 'false'
check "gateway stripped"     '.NetworkingConfig.EndpointsConfig.mynet | has("Gateway")' 'false'
check "HostConfig preserved" '.HostConfig.Binds' '["/a:/b"]'

echo "auto hostname (== id prefix) dropped; dynamic IP -> no IPAMConfig, MAC still kept"
BODY=$(build_create_body "$NEW" '{"Id":"'"$ID"'","Config":{"Hostname":"abcdef012345","Env":[],"Labels":{}},"HostConfig":{"NetworkMode":"mynet"},"NetworkSettings":{"Networks":{"mynet":{"IPAMConfig":null,"MacAddress":"02:42:0a:07:00:99"}}}}')
check "auto hostname dropped" '. | has("Hostname")' 'false'
check "no IPAMConfig"         '.NetworkingConfig.EndpointsConfig.mynet | has("IPAMConfig")' 'false'
check "MAC still preserved"   '.NetworkingConfig.EndpointsConfig.mynet.MacAddress' '"02:42:0a:07:00:99"'

echo "host network mode: no NetworkingConfig (falls through to HostConfig)"
BODY=$(build_create_body "$NEW" '{"Id":"'"$ID"'","Config":{"Hostname":"h"},"HostConfig":{"NetworkMode":"host"},"NetworkSettings":{"Networks":{"host":{}}}}')
check "no NetworkingConfig" '. | has("NetworkingConfig")' 'false'

echo "default bridge: unchanged - no NetworkingConfig (regression guard for the common case)"
BODY=$(build_create_body "$NEW" '{"Id":"'"$ID"'","Config":{"Hostname":"abcdef012345"},"HostConfig":{"NetworkMode":"default"},"NetworkSettings":{"Networks":{"bridge":{"IPAddress":"172.17.0.2"}}}}')
check "no NetworkingConfig" '. | has("NetworkingConfig")' 'false'

echo "two user networks: primary attached at create; the rest discoverable for connect"
INS='{"Id":"'"$ID"'","Config":{"Hostname":"h2"},"HostConfig":{"NetworkMode":"net1"},"NetworkSettings":{"Networks":{"net1":{"IPAMConfig":{"IPv4Address":"10.0.1.5"}},"net2":{"IPAMConfig":{"IPv4Address":"10.0.2.5"}}}}}'
BODY=$(build_create_body "$NEW" "$INS")
check "primary net1 at create" '.NetworkingConfig.EndpointsConfig | keys' '["net1"]'
# tr -d '\r': jq on Alpine (where this runs in CI) emits LF, but a Windows jq used for local dev
# emits CRLF that would break these shell-level string compares - the impl itself needs no such
# guard. primary/extras mirror recreate_container's connect-the-rest loop.
prim=$(primary_net "$INS" | tr -d '\r')
[ "$prim" = "net1" ] && echo "  ok   primary_net = net1" || { echo "  FAIL primary_net: <$prim>"; fail=1; }
extras=$(for n in $(user_nets "$INS" | tr -d '\r'); do [ "$n" = "$prim" ] && continue; printf '%s ' "$n"; done)
[ "$extras" = "net2 " ] && echo "  ok   extras to connect = net2" || { echo "  FAIL extras: <$extras>"; fail=1; }

echo "-----"
if [ "$fail" -eq 0 ]; then echo "PASS"; exit 0; else echo "FAIL"; exit 1; fi
