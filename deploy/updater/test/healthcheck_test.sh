#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 g-guglielmi
#
# Test for healthcheck.sh (the container HEALTHCHECK): a fake Docker Engine answers /_ping on a unix
# socket (python3), and the check must be healthy with no heartbeat or a fresh one, and unhealthy
# with a stale or malformed heartbeat, no socket, or an Engine that stopped answering. Runs the
# script under sh (dash on the CI runner), as the image's busybox sh would.
set -u
DIR=$(cd "$(dirname "$0")/.." && pwd)
HC="$DIR/healthcheck.sh"
command -v python3 >/dev/null 2>&1 || { echo "SKIP: python3 not installed"; exit 0; }
command -v curl >/dev/null 2>&1 || { echo "SKIP: curl not installed"; exit 0; }

T=$(mktemp -d)
SOCK="$T/docker.sock"
python3 - "$SOCK" <<'PY' &
import socket, sys
s = socket.socket(socket.AF_UNIX)
s.bind(sys.argv[1])
s.listen(8)
while True:
    c, _ = s.accept()
    c.recv(4096)
    c.sendall(b"HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: 2\r\nConnection: close\r\n\r\nOK")
    c.close()
PY
SRV=$!
trap 'kill "$SRV" 2>/dev/null; rm -rf "$T"' EXIT
for _ in $(seq 1 50); do [ -S "$SOCK" ] && break; sleep 0.1; done

fail=0
run() { # desc want-exit [VAR=value ...]
  desc=$1; want=$2; shift 2
  env ARGUS_DOCKER_SOCK="$SOCK" ARGUS_HEARTBEAT_FILE="$T/hb" "$@" sh "$HC" >"$T/out" 2>&1
  got=$?
  if [ "$got" = "$want" ]; then echo "  ok   $desc: $(cat "$T/out")"; else echo "  FAIL $desc: exit $got, want $want: $(cat "$T/out")"; fail=1; fi
}

echo "healthcheck.sh"
rm -f "$T/hb"
run "no heartbeat yet (socket only)" 0
echo "$(date +%s) 60" > "$T/hb"
run "fresh heartbeat" 0
echo "$(( $(date +%s) - 120 )) 60" > "$T/hb"
run "stale heartbeat" 1
echo "garbage" > "$T/hb"
run "malformed heartbeat" 1
echo "$(date +%s)" > "$T/hb"
run "heartbeat without a max age" 1
rm -f "$T/hb"
run "no Docker socket" 1 ARGUS_DOCKER_SOCK="$T/missing.sock"
kill "$SRV" 2>/dev/null; wait "$SRV" 2>/dev/null
run "Engine not answering" 1

exit "$fail"
