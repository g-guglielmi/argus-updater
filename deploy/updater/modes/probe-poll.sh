# shellcheck shell=sh
# argus-updater - mode: probe-poll (opt-in compose sidecar).
#
# Outbound-only sites can't be pushed to, so updates are pull-based but Argus-coordinated: this
# long-running sidecar asks Argus for the fleet target version and, when it differs from what the
# proxy runs, rewrites ARGUS_PROBE_TAG in the compose .env and recreates the proxy service. Argus is
# the control plane; the probe converges autonomously.
#
# Unlike the one-shot probe-recreate mode (Engine-API config-clone), this drives `docker compose` so
# the compose .env stays the source of truth - a later `docker compose up` won't revert the image.
# It therefore only makes sense in a compose deployment, and needs the docker compose plugin (baked
# into this image).
#
# It reads the check-in credential the proxy stored at enrollment from the shared probe volume
# (mounted read-only at /probe), so no token needs to be supplied twice.
set -eu

COMPOSE_DIR="${ARGUS_COMPOSE_DIR:-/compose}"
COMPOSE_FILE="$COMPOSE_DIR/docker-compose.yml"
ENV_FILE="$COMPOSE_DIR/.env"
META="${ARGUS_PROBE_META:-/probe/enroll/proxy.env}"
INTERVAL="${ARGUS_UPDATE_INTERVAL:-300}"

echo "argus-updater[poll]: starting (poll ${INTERVAL}s, compose $COMPOSE_FILE)"

while true; do
  # The proxy writes PROBE_TOKEN + CHECKIN_URL here at enrollment; may be absent early on.
  PROBE_TOKEN=""; CHECKIN_URL=""
  if [ -f "$META" ]; then
    # shellcheck disable=SC1090
    . "$META" 2>/dev/null || true
  fi

  if [ -n "$PROBE_TOKEN" ] && [ -n "$CHECKIN_URL" ]; then
    # Advertise self-update capability + read the fleet target. We deliberately DON'T report a
    # version: the proxy container is the authoritative version reporter, and Argus keeps the last
    # known version when a check-in omits it (so this sidecar never clobbers it).
    RESP=$(curl -sS -m 15 \
      -H "Authorization: Bearer $PROBE_TOKEN" -H 'Content-Type: application/json' \
      -d "$(jq -nc '{version:"", selfupdate:true}')" \
      "$CHECKIN_URL" 2>/dev/null || echo '')
    TARGET=$(echo "$RESP" | jq -r '.target // empty' 2>/dev/null || true)
    UPDATE=$(echo "$RESP" | jq -r '.update // empty' 2>/dev/null || true)

    # A dashboard "Update now" (the one-shot .update) forces a pull+recreate even at the same tag (so
    # a rolling :latest picks up a newer digest); otherwise converge on the fleet target by tag.
    # "latest" maps to the rolling tag; a pin (e.g. 7.0.29-r1) maps to itself.
    TAG=""; FORCE=0
    if [ -n "$UPDATE" ]; then
      TAG="latest"; [ "$UPDATE" != "latest" ] && TAG="$UPDATE"; FORCE=1
    elif [ -n "$TARGET" ]; then
      TAG="latest"; [ "$TARGET" != "latest" ] && TAG="$TARGET"
    fi

    if [ -n "$TAG" ]; then
      CUR=$(sed -n 's/^ARGUS_PROBE_TAG=//p' "$ENV_FILE" 2>/dev/null || true)
      if [ "$FORCE" = "1" ] || [ "$TAG" != "$CUR" ]; then
        echo "argus-updater[poll]: converging proxy to tag $TAG (current '${CUR:-unset}', force=$FORCE)"
        touch "$ENV_FILE"
        grep -v -E '^ARGUS_PROBE_TAG=' "$ENV_FILE" > "$ENV_FILE.tmp" 2>/dev/null || true
        echo "ARGUS_PROBE_TAG=$TAG" >> "$ENV_FILE.tmp"
        mv "$ENV_FILE.tmp" "$ENV_FILE"
        # Recreate only the proxy service (not this sidecar, so it can't kill itself mid-update). A
        # fresh pull that changes the image digest makes `up -d` recreate; an unchanged digest is a
        # no-op.
        if docker compose -f "$COMPOSE_FILE" pull proxy && docker compose -f "$COMPOSE_FILE" up -d proxy; then
          echo "argus-updater[poll]: proxy updated to $TAG"
        else
          echo "argus-updater[poll]: update to $TAG failed; will retry next tick" >&2
        fi
      fi
    fi
  fi

  sleep "$INTERVAL"
done
