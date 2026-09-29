#!/bin/sh
# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 g-guglielmi

# Container health for argus-updater (Docker HEALTHCHECK, shown by the Unraid GUI and Dockhand):
# healthy while the Docker Engine answers on the socket (the sidecar's whole job goes through it)
# and, for the long-running modes, while the watch loop keeps going round. Each loop writes
# "<unix time> <max age>" to the heartbeat file at every round; a loop stuck longer than its own
# max age (an update in progress included) is unhealthy. No heartbeat yet (starting, or the
# one-shot probe-recreate mode) checks the socket only. Exit 0 = healthy, 1 = unhealthy.
SOCK="${ARGUS_DOCKER_SOCK:-/var/run/docker.sock}"
HEARTBEAT="${ARGUS_HEARTBEAT_FILE:-/tmp/argus-updater.heartbeat}"

fail() { echo "unhealthy: $*"; exit 1; }

[ -S "$SOCK" ] || fail "no Docker socket at $SOCK"
_ping=$(curl -s -m 5 --unix-socket "$SOCK" http://localhost/_ping 2>/dev/null || true)
[ "$_ping" = "OK" ] || fail "the Docker Engine does not answer on $SOCK"

if [ -f "$HEARTBEAT" ]; then
  _at=""; _max=""
  read -r _at _max < "$HEARTBEAT" || true
  case "$_at" in ''|*[!0-9]*) fail "unreadable heartbeat in $HEARTBEAT";; esac
  case "$_max" in ''|*[!0-9]*) fail "unreadable heartbeat in $HEARTBEAT";; esac
  _age=$(( $(date +%s) - _at ))
  [ "$_age" -le "$_max" ] || fail "the watch loop last went round ${_age}s ago (allowed ${_max}s)"
fi
echo "healthy"
exit 0
