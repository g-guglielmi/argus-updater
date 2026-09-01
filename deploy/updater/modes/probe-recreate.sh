# shellcheck shell=sh
# argus-updater - mode: probe-recreate (one-shot).
#
# A container can't cleanly `docker rm -f` itself mid-update, so the argus-probe proxy spawns THIS
# short-lived sister container (Docker socket mounted, run with --rm) to recreate the proxy on a new
# image, then exit. It uses the shared recreate engine - the SAME config-clone + verify + rollback
# the core uses - so the two paths can never drift.
#
# Inputs (env): ARGUS_RECREATE_TARGET = the proxy container id/name; ARGUS_RECREATE_TAG = the image
# tag to converge on (e.g. "7.0.29-r2" or "latest"). The proxy runs an ACTIVE Zabbix proxy (dials
# out, no listening HTTP endpoint), so verify is container-stability only - no /healthz.
set -eu

TARGET="${ARGUS_RECREATE_TARGET:?set ARGUS_RECREATE_TARGET}"
TAG="${ARGUS_RECREATE_TAG:?set ARGUS_RECREATE_TAG}"
RECREATE_NOUN="proxy"

log()      { echo "argus-updater[recreate]: $*"; }
progress() { echo "argus-updater[recreate]: $*"; }

# Resolve the real container name + the new image (its repo, retagged).
INSPECT=$(api GET "/containers/$TARGET/json")
NAME=$(printf '%s' "$INSPECT" | jq -r '.Name // empty' | sed 's#^/##')
CUR_IMAGE=$(printf '%s' "$INSPECT" | jq -r '.Config.Image // empty')
if [ -z "$NAME" ] || [ -z "$CUR_IMAGE" ]; then
  echo "argus-updater[recreate]: could not inspect target '$TARGET' - aborting (proxy untouched)" >&2
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
