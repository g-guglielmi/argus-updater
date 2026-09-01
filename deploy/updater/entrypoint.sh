#!/bin/sh
# argus-updater dispatcher: one socket-holding image, several modes.
#
# The recreate engine (pull -> clone-config -> verify -> rollback) is shared by every mode so the
# core and the probes can never drift. Pick a mode with ARGUS_UPDATER_MODE (default: core, so an
# existing core sidecar that sets no mode keeps working unchanged):
#
#   core            long-running; watch the shared /update dir and recreate the CORE on request
#                   (dashboard-triggered; /healthz-aware; channel-preserving). [default]
#   probe-watch     long-running socket-holding sidecar; poll Argus and recreate the PROXY via the
#                   Engine API - the proxy stays socket-free. The one probe updater (run/compose/VM).
#   probe-recreate  one-shot; recreate a target container on a new image, then exit. The self-update
#                   primitive a long-running updater uses to recreate ITSELF (a --rm sister).
set -eu

MODE="${ARGUS_UPDATER_MODE:-core}"
LIBDIR=/usr/local/lib/argus-updater

# Shared engine (functions: api, verify, recreate_container, image_repo/tag).
. "$LIBDIR/lib/recreate.sh"

case "$MODE" in
  core)           . "$LIBDIR/modes/core.sh" ;;
  probe-watch)    . "$LIBDIR/modes/probe-watch.sh" ;;
  probe-recreate) . "$LIBDIR/modes/probe-recreate.sh" ;;
  *)
    echo "argus-updater: unknown ARGUS_UPDATER_MODE='$MODE' (want: core | probe-watch | probe-recreate)" >&2
    exit 2
    ;;
esac
