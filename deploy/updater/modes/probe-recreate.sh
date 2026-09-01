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
# (these targets have no listening HTTP endpoint).
set -eu

TARGET="${ARGUS_RECREATE_TARGET:?set ARGUS_RECREATE_TARGET}"
TAG="${ARGUS_RECREATE_TAG:?set ARGUS_RECREATE_TAG}"
RECREATE_NOUN="container"

log()      { echo "argus-updater[recreate]: $*"; }
progress() { echo "argus-updater[recreate]: $*"; }

# Resolve the real container name + the new image (its repo, retagged).
INSPECT=$(api GET "/containers/$TARGET/json")
NAME=$(printf '%s' "$INSPECT" | jq -r '.Name // empty' | sed 's#^/##')
CUR_IMAGE=$(printf '%s' "$INSPECT" | jq -r '.Config.Image // empty')
if [ -z "$NAME" ] || [ -z "$CUR_IMAGE" ]; then
  echo "argus-updater[recreate]: could not inspect target '$TARGET' - aborting (target untouched)" >&2
  exit 1
fi
NEW_IMAGE="$(image_repo "$CUR_IMAGE"):$TAG"

if recreate_container "$NAME" "$NEW_IMAGE"; then
  log "$NAME updated to $NEW_IMAGE"
  exit 0
else
  echo "argus-updater[recreate]: $RECREATE_ERR" >&2
  exit 1
fi
