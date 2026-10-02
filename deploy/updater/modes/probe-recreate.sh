# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 g-guglielmi

# shellcheck shell=sh
# argus-updater - mode: probe-recreate (one-shot; the self-update primitive).
#
# A long-running container can't cleanly `docker rm -f` itself mid-update, so it spawns THIS
# short-lived sister (Docker socket mounted, run with --rm) to recreate a target container on a new
# image, then exit. It uses the shared recreate engine - the SAME config-clone + verify + rollback
# every mode uses - so the paths can never drift. Its main use now is the updater updating ITSELF
# (probe-watch spawns it against its own container).
#
# Inputs (env): ARGUS_RECREATE_TARGET = the container id/name to recreate; ARGUS_RECREATE_TAG = the
# image tag to converge on (e.g. "latest" or a pin). Verify is container-stability only - no /healthz
# (these targets have no listening HTTP endpoint). Optional: ARGUS_RECREATE_NOUN names the target in
# its messages ("sidecar"), and ARGUS_JOB_FILE + ARGUS_JOB_ID take each step into that job status file
# (the core's updater hands them over, so Settings shows its self-update to the end).
set -eu

TARGET="${ARGUS_RECREATE_TARGET:?set ARGUS_RECREATE_TARGET}"
TAG="${ARGUS_RECREATE_TAG:?set ARGUS_RECREATE_TAG}"
DIGEST="${ARGUS_RECREATE_DIGEST:-}"   # optional: the pull must resolve to it
if [ -n "$DIGEST" ] && ! valid_digest "$DIGEST"; then
  echo "argus-updater[recreate]: ARGUS_RECREATE_DIGEST is malformed - aborting (target untouched)" >&2
  exit 1
fi
if ! valid_tag "$TAG"; then
  echo "argus-updater[recreate]: '$TAG' is not a valid image tag - aborting (target untouched)" >&2
  exit 1
fi
RECREATE_NOUN="${ARGUS_RECREATE_NOUN:-container}"
JOB_FILE="${ARGUS_JOB_FILE:-}"
JOB_ID="${ARGUS_JOB_ID:-}"

log()      { echo "argus-updater[recreate]: $*"; }
progress() {
  echo "argus-updater[recreate]: $*"
  if [ -n "$JOB_FILE" ] && [ -n "$JOB_ID" ]; then job_write "$JOB_FILE" "$JOB_ID" running "$*"; fi
}
job_end() { # STATE MESSAGE
  if [ -n "$JOB_FILE" ] && [ -n "$JOB_ID" ]; then job_write "$JOB_FILE" "$JOB_ID" "$1" "$2"; fi
}

# Resolve the real container name + the new image (its repo, retagged).
INSPECT=$(api GET "/containers/$TARGET/json")
NAME=$(printf '%s' "$INSPECT" | jq -r '.Name // empty' | sed 's#^/##')
CUR_IMAGE=$(printf '%s' "$INSPECT" | jq -r '.Config.Image // empty')
if [ -z "$NAME" ] || [ -z "$CUR_IMAGE" ]; then
  echo "argus-updater[recreate]: could not inspect target '$TARGET' - aborting (target untouched)" >&2
  job_end failed "the helper could not find the $RECREATE_NOUN to swap; nothing changed"
  exit 1
fi
NEW_IMAGE="$(image_repo "$CUR_IMAGE"):$TAG"

if recreate_container "$NAME" "$NEW_IMAGE" "$DIGEST"; then
  log "$NAME updated to $NEW_IMAGE"
  # We run the image we just put in place, so its version is ours.
  job_end success "done: the $RECREATE_NOUN now runs $(cat /etc/argus-updater.version 2>/dev/null || echo "$TAG")"
  exit 0
else
  echo "argus-updater[recreate]: $RECREATE_ERR" >&2
  job_end failed "$RECREATE_ERR"
  exit 1
fi
