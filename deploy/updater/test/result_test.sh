#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 g-guglielmi
#
# Test for lib/result.sh: the record of an update that didn't take, which the probe sidecar sends
# with its check-in. Pure jq, no daemon.
set -u
DIR=$(cd "$(dirname "$0")/.." && pwd)
command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not installed"; exit 0; }
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
ARGUS_RESULT_FILE="$TMP/result"
# shellcheck source=/dev/null
. "$DIR/lib/result.sh"

fail=0
get() { jq -r "$1" "$RESULT_FILE" | tr -d '\r'; }
check() { # desc got want
  if [ "$2" = "$3" ]; then echo "  ok   $1"; else echo "  FAIL $1: got <$2> want <$3>"; fail=1; fi
}

echo "nothing failed yet"
check "the report is null" "$(result_report)" null

echo "an update that didn't take is recorded"
result_set updater latest "the image is not signed by its build; refusing to run it"
check "what" "$(get .what)" updater
check "tag"  "$(get .tag)" latest
check "why"  "$(get .why)" "the image is not signed by its build; refusing to run it"
check "the report carries the four fields" "$(result_report | jq -r 'keys | join(",")' | tr -d '\r')" "at,tag,what,why"
AT=$(get .at)
case "$AT" in ''|*[!0-9]*) echo "  FAIL at is not a time: <$AT>"; fail=1;; *) echo "  ok   at is a time";; esac

echo "the same failure met again keeps its record"
jq -c '.at = 1000' "$RESULT_FILE" > "$RESULT_FILE.t" && mv "$RESULT_FILE.t" "$RESULT_FILE"
result_set updater latest "the image is not signed by its build; refusing to run it"
check "same time" "$(get .at)" 1000

echo "a new try that failed the same way is a new record"
result_set updater latest "the image is not signed by its build; refusing to run it" again
check "a new time" "$([ "$(get .at)" -gt 1000 ] && echo newer)" newer

echo "another reason, tag or kind replaces it"
jq -c '.at = 1000' "$RESULT_FILE" > "$RESULT_FILE.t" && mv "$RESULT_FILE.t" "$RESULT_FILE"
result_set updater latest "pull of the image failed after 3 attempts"
check "new reason, new time" "$([ "$(get .at)" -gt 1000 ] && echo newer)" newer
result_set probe 7.0.32-r27 "the new proxy failed its health check"
check "the newest failure is the one kept" "$(get .what),$(get .tag)" "probe,7.0.32-r27"

echo "a reason is one line of at most 300 characters"
LONG=$(printf 'x%.0s' $(seq 1 400))
result_set probe latest "$(printf 'line one\nline two\t%s' "$LONG")"
check "no line break, no tab" "$(get '.why | test("[\n\t]")')" false
check "starts as written"     "$(get '.why[0:17]')" "line one line two"
check "cut at 300"            "$(get '.why | length')" 300

echo "an update that went through clears its own kind only"
result_clear updater
check "another kind's record stays" "$(get .what)" probe
result_clear probe
check "gone" "$([ -e "$RESULT_FILE" ] && echo there || echo gone)" gone
check "the report is null again" "$(result_report)" null

echo "a broken file reports nothing"
echo 'not json' > "$RESULT_FILE"
check "null" "$(result_report)" null
echo '"a string"' > "$RESULT_FILE"
check "null for a non-object" "$(result_report)" null
result_set updater latest "still records over a broken file"
check "recorded" "$(get .what)" updater

if [ "$fail" = 0 ]; then echo "PASS"; else echo "FAILED"; exit 1; fi
