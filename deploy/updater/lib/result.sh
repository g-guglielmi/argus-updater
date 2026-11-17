# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 g-guglielmi

# shellcheck shell=sh
# argus-updater - why the last update didn't take, for the probe sidecar's check-in.
#
# A sidecar that refuses an image or rolls one back knows why, and until now only its own log said
# so: Argus saw nothing but the old version still running, twenty minutes later. The reason is kept
# here as one small record, {what: probe|updater, tag, at, why}, and goes out with every check-in
# as update_result until an update of that kind goes through. Argus tells one record from the next
# by its `at`, so a record that stays the same is told once.
#
# The file lives in the container's own filesystem: it survives a restart of the sidecar (the
# rollback of its own update is one) and goes with the container when an update replaces it.
RESULT_FILE="${ARGUS_RESULT_FILE:-/tmp/argus-updater.result}"

# result_set WHAT TAG WHY [again] - record that the update of WHAT to TAG didn't take. The same
# failure met again keeps its record and its time (the fleet target is retried every round, and one
# refusal is one thing to tell); "again" marks a new try that failed, which is told even when it
# failed the same way (an admin clicked Update once more). WHY is one line, at most 300 characters.
result_set() {
  _rw="$1"; _rt="$2"
  _ry=$(printf '%s' "$3" | tr '[:cntrl:]' ' ' | cut -c1-300)
  if [ "${4:-}" != "again" ] && jq -e --arg w "$_rw" --arg t "$_rt" --arg y "$_ry" \
       '.what == $w and .tag == $t and .why == $y' "$RESULT_FILE" >/dev/null 2>&1; then
    return 0
  fi
  jq -nc --arg w "$_rw" --arg t "$_rt" --arg y "$_ry" --argjson at "$(date +%s)" \
     '{what:$w, tag:$t, at:$at, why:$y}' > "$RESULT_FILE.tmp" 2>/dev/null \
    && mv "$RESULT_FILE.tmp" "$RESULT_FILE" 2>/dev/null || true
}

# result_clear WHAT - an update of WHAT went through: what failed before it is history.
result_clear() {
  if jq -e --arg w "$1" '.what == $w' "$RESULT_FILE" >/dev/null 2>&1; then rm -f "$RESULT_FILE"; fi
}

# result_report - the record for the check-in body, or null when there is none (or it is unreadable).
result_report() {
  _rr=$(jq -c 'select(type == "object" and (.why | type) == "string") | {what, tag, at, why}' "$RESULT_FILE" 2>/dev/null || true)
  if [ -n "$_rr" ]; then printf '%s' "$_rr"; else printf 'null'; fi
}
