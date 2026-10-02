#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 g-guglielmi
#
# Test for lib/collectors.sh: when the core mode installs the core host's collectors, and what it
# reports in collectors.json. Pure: api, docker and the clock are stubs; no Docker daemon, only jq.
set -u
DIR=$(cd "$(dirname "$0")/.." && pwd)
command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not installed"; exit 0; }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
UPDATE_DIR="$TMP"
# shellcheck source=/dev/null
. "$DIR/lib/collectors.sh"

# --- stubs ---
IMAGE="sha256:aaa"         # the core container's image id
LABELLED=1                 # the image carries collectors
DOCKER_OUT='{"version":"v0.6.2","installed":["argus_http.py"],"unchanged":["argus_tcp.py"]}'
DOCKER_RC=0
CLOCK=1000000
now() { echo "2026-10-02T00:00:00Z"; }
log() { :; }
epoch() { echo "$CLOCK"; }
resolve_core() { echo argus; }
api() {
  case "$2" in
    /containers/argus/json) printf '{"Image":"%s"}' "$IMAGE" ;;
    /images/*) if [ "$LABELLED" = 1 ]; then echo '{"Config":{"Labels":{"io.argus.collectors":"/collectors"}}}'; else echo '{"Config":{"Labels":null}}'; fi ;;
  esac
}
docker() { echo "$*" >> "$TMP/calls"; printf '%s\n' "$DOCKER_OUT"; return "$DOCKER_RC"; }

fail=0
calls() { [ -f "$TMP/calls" ] && wc -l < "$TMP/calls" | tr -d ' ' || echo 0; }
report() { jq -r "$1" "$COLLECTORS_FILE" | tr -d '\r'; }
check() { # desc got want
  if [ "$2" = "$3" ]; then echo "  ok   $1"; else echo "  FAIL $1: got <$2> want <$3>"; fail=1; fi
}

echo "an image without the label is skipped, once"
LABELLED=0
sync_collectors
check "no docker run"   "$(calls)" 0
check "state skipped"   "$(report .state)" skipped
check "says why"        "$(report '.message | test("doesn.t carry")')" true
sync_collectors
check "not retried for the same image" "$(calls)" 0

echo "a new image with collectors installs them"
LABELLED=1; IMAGE="sha256:bbb"
sync_collectors
check "one docker run"     "$(calls)" 1
check "state ok"           "$(report .state)" ok
check "version reported"   "$(report .version)" v0.6.2
check "installed reported" "$(report '.installed | join(",")')" argus_http.py
check "no message"         "$(report 'has("message")')" false
check "runs the core's image, folder bound, as root, offline" \
  "$(grep -c -- '--network none --user 0:0 .*type=bind,src=/usr/lib/zabbix/externalscripts,dst=/dst --entrypoint /argus sha256:bbb install-collectors /dst' "$TMP/calls")" 1

echo "the same image: again only a day later"
CLOCK=$((CLOCK + 3600)); sync_collectors
check "not within the day" "$(calls)" 1
CLOCK=$((CLOCK + 86400)); sync_collectors
check "after a day"        "$(calls)" 2

echo "a host without the folder is skipped"
IMAGE="sha256:ccc"; DOCKER_RC=125
DOCKER_OUT='docker: Error response from daemon: invalid mount config for type "bind": bind source path does not exist: /usr/lib/zabbix/externalscripts.'
sync_collectors
check "state skipped"  "$(report .state)" skipped
check "names the folder" "$(report '.message | test("/usr/lib/zabbix/externalscripts")')" true
sync_collectors
check "not retried"    "$(calls)" 3

echo "a failure says why and retries after ten minutes"
IMAGE="sha256:ddd"; DOCKER_RC=1
DOCKER_OUT='argus install-collectors: could not write argus_http.py in /dst: read-only file system'
sync_collectors
check "state failed"   "$(report .state)" failed
check "the reason, without the prefix" "$(report .message)" "could not write argus_http.py in /dst: read-only file system"
CLOCK=$((CLOCK + 60)); sync_collectors
check "not within ten minutes" "$(calls)" 4
CLOCK=$((CLOCK + 600)); DOCKER_RC=0; DOCKER_OUT='{"version":"v0.6.2","installed":[],"unchanged":["argus_http.py"]}'
sync_collectors
check "retried"        "$(calls)" 5
check "then ok"        "$(report .state)" ok
check "nothing written that time" "$(report '.installed | length')" 0

exit $fail
