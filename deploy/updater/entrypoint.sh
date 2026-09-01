#!/bin/sh
# argus-updater dispatcher: one socket-holding image, several modes.
#
# The recreate engine (pull -> clone-config -> verify -> rollback) is shared by every mode so the
# core and the probes can never drift. Pick a mode with ARGUS_UPDATER_MODE (default: core, so an
# existing core sidecar that sets no mode keeps working unchanged):
#
#   core            long-running; watch the shared /update dir and recreate the CORE on request
#                   (dashboard-triggered; /healthz-aware; channel-preserving). [default]
#   probe-recreate  one-shot; recreate the argus-probe PROXY on a new image, then exit
#                   (spawned by the proxy as a --rm sister container - socket-on-proxy model).
#   probe-watch     long-running socket-holding sidecar (NO compose); poll Argus and recreate the
#                   proxy via the Engine API - the proxy stays socket-free. Best for docker-run.
#   probe-poll      long-running compose sidecar; poll Argus for the fleet target and converge the
#                   proxy via `docker compose` (keeps the compose .env authoritative).
set -eu

MODE="${ARGUS_UPDATER_MODE:-core}"
LIBDIR=/usr/local/lib/argus-updater

# Shared engine (functions: api, verify, recreate_container, image_repo/tag).
. "$LIBDIR/lib/recreate.sh"

case "$MODE" in
  core)           . "$LIBDIR/modes/core.sh" ;;
  probe-recreate) . "$LIBDIR/modes/probe-recreate.sh" ;;
  probe-watch)    . "$LIBDIR/modes/probe-watch.sh" ;;
  probe-poll)     . "$LIBDIR/modes/probe-poll.sh" ;;
  *)
    echo "argus-updater: unknown ARGUS_UPDATER_MODE='$MODE' (want: core | probe-recreate | probe-watch | probe-poll)" >&2
    exit 2
    ;;
esac
