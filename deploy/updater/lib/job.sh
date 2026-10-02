# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 g-guglielmi

# shellcheck shell=sh
# argus-updater - job status files: what an update is doing, step by step, for the core's Settings.
#
# A job file is {id, state: running|success|failed, started_at, finished_at, message, steps: [{at,
# msg}], ...}: the core shows its steps while the job runs and after, until an admin closes it, so a
# page reload never hides an update that is still going. Every write is atomic (tmp + mv) so the core
# never reads half a file.

job_now() { date -u +%Y-%m-%dT%H:%M:%SZ; }

# job_write FILE ID STATE MESSAGE [EXTRA_JSON] - set the job's state, add MESSAGE as a step (unless
# empty) and merge EXTRA_JSON's fields in. A file left by another job id starts over.
job_write() {
  _jf="$1"; _jid="$2"; _js="$3"; _jm="$4"; _jx="${5:-}"
  [ -z "$_jx" ] && _jx='{}'
  _jat=$(job_now)
  _jcur=$(cat "$_jf" 2>/dev/null || true)
  if ! printf '%s' "$_jcur" | jq -e --arg id "$_jid" '.id == $id' >/dev/null 2>&1; then
    _jcur=$(jq -nc --arg id "$_jid" --arg at "$_jat" '{id:$id, started_at:$at, steps:[]}')
  fi
  printf '%s' "$_jcur" | jq -c --arg s "$_js" --arg m "$_jm" --arg at "$_jat" --argjson x "$_jx" '
      . + $x + {state:$s}
      + (if $m == "" then {} else {message:$m, steps:((.steps // []) + [{at:$at, msg:$m}])} end)
      + (if ($s == "success" or $s == "failed") then {finished_at:$at} else {} end)' \
    > "$_jf.tmp" 2>/dev/null && mv "$_jf.tmp" "$_jf" 2>/dev/null || true
}

# job_get FILE FIELD - one field of the job file ("" when it or the file is missing).
job_get() { jq -r --arg k "$2" '.[$k] // empty' "$1" 2>/dev/null || true; }
