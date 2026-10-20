#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 g-guglielmi
#
# Test for lib/hosttools.sh: when the core mode installs the core host's scripts and units, and what
# it reports in host-tools.json. Pure: api, docker, hostname and the clock are stubs; only jq.
set -u
DIR=$(cd "$(dirname "$0")/.." && pwd)
command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not installed"; exit 0; }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
UPDATE_DIR="$TMP"
# shellcheck source=/dev/null
. "$DIR/lib/hosttools.sh"

# --- stubs ---
IMAGE="sha256:aaa"
LABELLED=1
MOUNTED=1                  # our container's /update mount is known
DOCKER_OUT='{"version":"v0.9.2","installed":["/usr/local/sbin/argus-os-report","/etc/systemd/system/argus-os-report.timer"],"unchanged":[],"units_changed":["argus-os-report.timer"],"apply":true}'
DOCKER_RC=0
CLOCK=1000000
now() { echo "2026-10-21T00:00:00Z"; }
log() { :; }
epoch() { echo "$CLOCK"; }
resolve_core() { echo argus; }
hostname() { echo selfid; }
api() {
  case "$2" in
    /containers/argus/json) printf '{"Image":"%s"}' "$IMAGE" ;;
    /containers/selfid/json) if [ "$MOUNTED" = 1 ]; then echo '{"Mounts":[{"Destination":"/update","Source":"/docker/argus-update"}]}'; else echo '{"Mounts":[]}'; fi ;;
    /images/*) if [ "$LABELLED" = 1 ]; then echo '{"Config":{"Labels":{"io.argus.host-tools":"/host-tools"}}}'; else echo '{"Config":{"Labels":null}}'; fi ;;
  esac
}
docker() { echo "$*" >> "$TMP/calls"; printf '%s\n' "$DOCKER_OUT"; return "$DOCKER_RC"; }

fail=0
calls() { [ -f "$TMP/calls" ] && wc -l < "$TMP/calls" | tr -d ' ' || echo 0; }
report() { jq -r "$1" "$HOST_TOOLS_FILE" | tr -d '\r'; }
check() { # desc got want
  if [ "$2" = "$3" ]; then echo "  ok   $1"; else echo "  FAIL $1: got <$2> want <$3>"; fail=1; fi
}

echo "a host that was never set up as a core is skipped"
sync_host_tools
check "no docker run"  "$(calls)" 0
check "state skipped"  "$(report .state)" skipped
check "says why"       "$(report '.message | test("not set up as an Argus core")')" true

echo "a core without the label is skipped, once"
touch "$TMP/os-status.json"
IMAGE="sha256:bbb"; LABELLED=0
sync_host_tools
check "no docker run"  "$(calls)" 0
check "state skipped"  "$(report .state)" skipped
check "says why"       "$(report '.message | test("doesn.t carry")')" true
sync_host_tools
check "not retried for the same image" "$(calls)" 0

echo "a new image with host tools installs them, as root, offline, both folders and the shared dir bound"
LABELLED=1; IMAGE="sha256:ccc"
sync_host_tools
check "one docker run"      "$(calls)" 1
check "state ok"            "$(report .state)" ok
check "version reported"    "$(report .version)" v0.9.2
check "installed reported"  "$(report '.installed | length')" 2
check "reload reported"     "$(report .apply)" true
check "the run" \
  "$(grep -c -- '--network none --user 0:0 .*src=/usr/local/sbin,dst=/host/usr/local/sbin .*src=/etc/systemd/system,dst=/host/etc/systemd/system .*src=/docker/argus-update,dst=/update --entrypoint /argus sha256:ccc install-host-tools --root /host --state-dir /docker/argus-update --update-dir /update' "$TMP/calls")" 1

echo "the same image: again only a day later"
CLOCK=$((CLOCK + 3600)); sync_host_tools
check "not within the day" "$(calls)" 1
CLOCK=$((CLOCK + 86400)); sync_host_tools
check "after a day"        "$(calls)" 2

echo "a host without systemd is skipped"
IMAGE="sha256:ddd"; DOCKER_RC=125
DOCKER_OUT='docker: Error response from daemon: invalid mount config for type "bind": bind source path does not exist: /etc/systemd/system.'
sync_host_tools
check "state skipped"  "$(report .state)" skipped
check "says why"       "$(report '.message | test("not a core VM")')" true

echo "a failure says why and retries after ten minutes"
IMAGE="sha256:eee"; DOCKER_RC=1
DOCKER_OUT='argus install-host-tools: could not write /usr/local/sbin/argus-os-report: read-only file system'
sync_host_tools
check "state failed"   "$(report .state)" failed
check "the reason, without the prefix" "$(report .message)" "could not write /usr/local/sbin/argus-os-report: read-only file system"
CLOCK=$((CLOCK + 60)); sync_host_tools
check "not within ten minutes" "$(calls)" 4
CLOCK=$((CLOCK + 600)); DOCKER_RC=0; DOCKER_OUT='{"version":"v0.9.2","installed":[],"unchanged":["/usr/local/sbin/argus-os-report"],"units_changed":[],"apply":false}'
sync_host_tools
check "retried"        "$(calls)" 5
check "then ok"        "$(report .state)" ok
check "nothing written that time" "$(report '.installed | length')" 0

echo "the shared dir's host path must be known"
IMAGE="sha256:fff"; MOUNTED=0
sync_host_tools
check "state failed"   "$(report .state)" failed
check "says what to set" "$(report '.message | test("ARGUS_HOST_UPDATE_DIR")')" true
check "no docker run"  "$(calls)" 5
ARGUS_HOST_UPDATE_DIR=/mnt/user/appdata/argus-update; IMAGE="sha256:ggg"; DOCKER_OUT='{"version":"v0.9.2","installed":[],"unchanged":[],"units_changed":[],"apply":false}'
sync_host_tools
check "the configured path is used" "$(grep -c -- 'src=/mnt/user/appdata/argus-update,dst=/update .*--state-dir /mnt/user/appdata/argus-update' "$TMP/calls")" 1

exit $fail
