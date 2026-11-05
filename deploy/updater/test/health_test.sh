#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 g-guglielmi
#
# Regression test for lib/recreate.sh's verify: a new container that crash-loops must be rolled
# back after a few restarts, not after the whole timeout (2026-11-05: a core that panicked at start
# restarted for 95 s before the rollback), and the reason must carry its last telling log line
# (the logs go with the container on the rollback). Pure: the Engine API is faked, sleep is a
# no-op; only jq, od and awk are needed.
set -u
DIR=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck source=/dev/null
. "$DIR/lib/recreate.sh"   # defines verify / log_last_line

command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not installed"; exit 0; }

fail=0
ok()   { echo "  ok   $1"; }
bad()  { echo "  FAIL $1"; fail=1; }

log() { :; }
sleep() { :; }
T=$(mktemp -d)
NL='
'

# frame STREAM TEXT - one Engine API log frame (a container without a TTY): Docker sends a frame
# per write, the newline inside it.
frame() {
  _len=${#2}
  printf '%b' "\\$(printf '%03o' "$1")\\000\\000\\000\\000\\000\\$(printf '%03o' $((_len / 256)))\\$(printf '%03o' $((_len % 256)))"
  printf '%s' "$2"
}

# A fake api: /json answers the next line of $T/states (the last one repeats), /logs the file
# $T/logs; $T/i counts the looks (one more than taken).
api() {
  case "$2" in
    */logs*) cat "$T/logs" ;;
    */json)
      _i=$(cat "$T/i" 2>/dev/null || echo 1)
      _n=$(wc -l < "$T/states")
      _l=$_i; [ "$_l" -gt "$_n" ] && _l=$_n
      sed -n "${_l}p" "$T/states"
      echo $((_i + 1)) > "$T/i" ;;
  esac
}
states() { printf '%s\n' "$@" > "$T/states"; rm -f "$T/i"; }
RUN='{"RestartCount":0,"Config":{"Tty":false},"State":{"Status":"running","Running":true,"Restarting":false,"ExitCode":0}}'
LOOP() { printf '{"RestartCount":%s,"Config":{"Tty":false},"State":{"Status":"restarting","Running":true,"Restarting":true,"ExitCode":2}}' "$1"; }
EXITED='{"RestartCount":0,"Config":{"Tty":false},"State":{"Status":"exited","Running":false,"Restarting":false,"ExitCode":137}}'

{ frame 1 '{"level":"INFO","msg":"probe enrollment enabled"}'"$NL"
  frame 2 'panic: pattern "DELETE /api/x/{name}/y" conflicts with pattern "DELETE /api/x/tokens/{id}":'"$NL"
  frame 2 '	both match some paths'"$NL"
  frame 2 'goroutine 1 [running]:'"$NL"
  frame 2 '	argus/main.go:186 +0x1bc5'"$NL"; } > "$T/logs"

echo "log_last_line: framed logs -> the panic's first line, not the stack's last"
got=$(log_last_line false < "$T/logs")
[ "$got" = 'panic: pattern "DELETE /api/x/{name}/y" conflicts with pattern "DELETE /api/x/tokens/{id}":' ] && ok "panic line" || bad "got <$got>"

echo "log_last_line: no panic -> the last non-empty line"
{ frame 1 "first$NL"; frame 1 "the last word$NL"; frame 1 "$NL"; } > "$T/plain"
got=$(log_last_line false < "$T/plain")
[ "$got" = "the last word" ] && ok "last line" || bad "got <$got>"

echo "log_last_line: a TTY container's logs are plain text"
got=$(printf 'one\npanic: boom\nstack\n' | log_last_line true)
[ "$got" = "panic: boom" ] && ok "tty panic line" || bad "got <$got>"

echo "log_last_line: a line over 255 bytes (two-byte frame length) is read whole, then cut at 300"
long=$(printf 'x%.0s' $(seq 1 400))
got=$({ frame 1 "$long$NL"; frame 1 "next$NL"; } | log_last_line false)
[ "$got" = "next" ] && ok "the frame after a long one lines up" || bad "got <$got>"
got=$(frame 1 "$long" | log_last_line false)
[ "${#got}" = "300" ] && ok "cut at 300" || bad "length ${#got}"

echo "verify: a crash loop rolls back after VERIFY_MAX_RESTARTS restarts, with the panic"
HEALTH_STABLE=20; VERIFY_TIMEOUT=90; VERIFY_MAX_RESTARTS=3
states "$(LOOP 0)" "$(LOOP 1)" "$(LOOP 2)" "$(LOOP 3)" "$RUN"
if verify argus; then bad "a crash loop passed"; else ok "failed"; fi
[ "$(cat "$T/i")" = "5" ] && ok "after 4 looks, not the whole timeout" || bad "looks: $(( $(cat "$T/i") - 1 ))"
case "$VERIFY_WHY" in "it crashed on start, 3 restarts (exit code 2): panic: pattern"*) ok "reason: $VERIFY_WHY" ;; *) bad "reason: $VERIFY_WHY" ;; esac

echo "verify: exited and staying down (no restart policy, stopped by hand) -> fails after 3 looks"
states "$EXITED"
if verify argus; then bad "a stopped container passed"; else ok "failed"; fi
[ "$(cat "$T/i")" = "4" ] && ok "after 3 looks" || bad "looks: $(( $(cat "$T/i") - 1 ))"
case "$VERIFY_WHY" in "it stopped and stayed down (exit code 137)"*) ok "reason names it" ;; *) bad "reason: $VERIFY_WHY" ;; esac

echo "verify: one restart, then steady -> healthy"
states "$(LOOP 1)" "$RUN"
if verify argus; then ok "passed"; else bad "failed: $VERIFY_WHY"; fi

echo "verify: never steady, never crashing -> the timeout, said so"
VERIFY_TIMEOUT=0
states "$RUN"
if verify argus; then bad "passed with no time"; else ok "failed"; fi
case "$VERIFY_WHY" in "it did not become healthy in 0s"*) ok "reason: timeout" ;; *) bad "reason: $VERIFY_WHY" ;; esac

rm -rf "$T"
[ "$fail" = 0 ] && echo "PASS" || { echo "FAILED"; exit 1; }
