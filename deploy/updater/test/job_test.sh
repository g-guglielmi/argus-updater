#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 g-guglielmi
#
# Test for lib/job.sh: the job status files the core shows an update's steps from. Pure jq, no daemon.
set -u
DIR=$(cd "$(dirname "$0")/.." && pwd)
command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not installed"; exit 0; }
# shellcheck source=/dev/null
. "$DIR/lib/job.sh"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
F="$TMP/updater-status.json"
fail=0
get() { jq -r "$1" "$F" | tr -d '\r'; }
check() { # desc got want
  if [ "$2" = "$3" ]; then echo "  ok   $1"; else echo "  FAIL $1: got <$2> want <$3>"; fail=1; fi
}

echo "a job starts, gathers steps and extra fields, and ends"
job_write "$F" job1 running "picked up" '{"from":"v0.2.11","tag":"latest"}'
check "id"            "$(get .id)" job1
check "running"       "$(get .state)" running
check "first step"    "$(get '.steps | length')" 1
check "extra merged"  "$(get .from)" v0.2.11
check "started"       "$(get 'has("started_at")')" true
check "not finished"  "$(get 'has("finished_at")')" false
job_write "$F" job1 running "pulling" '{"to_image":"sha256:new"}'
job_write "$F" job1 running ""
check "an empty message adds no step" "$(get '.steps | length')" 2
check "earlier fields kept" "$(get .from),$(get .to_image)" "v0.2.11,sha256:new"
job_write "$F" job1 success "done"
check "success"       "$(get .state)" success
check "finished"      "$(get 'has("finished_at")')" true
check "steps in order" "$(get '[.steps[].msg] | join(">")')" "picked up>pulling>done"
check "last message"  "$(get .message)" done
check "job_get reads a field" "$(job_get "$F" to_image | tr -d '\r')" sha256:new
check "job_get of a missing field is empty" "$(job_get "$F" nothing | tr -d '\r')" ""

echo "another job starts over"
job_write "$F" job2 running "picked up"
check "new id"        "$(get .id)" job2
check "old steps gone" "$(get '.steps | length')" 1
check "old fields gone" "$(get 'has("from")')" false

echo "a failure"
job_write "$F" job2 failed "the new sidecar failed to start - rolled back"
check "failed"        "$(get .state)" failed
check "why"           "$(get .message)" "the new sidecar failed to start - rolled back"
check "finished"      "$(get 'has("finished_at")')" true

echo "a missing or broken file is no error"
rm -f "$F"; printf 'not json' > "$F"
job_write "$F" job3 running "picked up"
check "rewritten"     "$(get .id)" job3

exit $fail
