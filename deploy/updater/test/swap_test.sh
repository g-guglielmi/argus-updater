#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 g-guglielmi
#
# Test for lib/recreate.sh's swap (recreate_container): when the Docker Engine refuses a step, the
# reason it gives must reach RECREATE_ERR, and the previous container must be running again. Found
# on 2026-11-17: a container already named <name>_old made the rename fail, nothing noticed (curl
# gives no exit code for a refused call), and the reason read "could not create the new container",
# the step after. Pure: the Engine API is faked; only jq is needed.
set -u
DIR=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck source=/dev/null
. "$DIR/lib/recreate.sh"

command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not installed"; exit 0; }

fail=0
check() { # desc got want
  if [ "$2" = "$3" ]; then echo "  ok   $1"; else echo "  FAIL $1: got <$2> want <$3>"; fail=1; fi
}
has() { # desc text part
  case "$2" in *"$3"*) echo "  ok   $1" ;; *) echo "  FAIL $1: <$2> lacks <$3>"; fail=1 ;; esac
}
before() { # desc text first then
  case "$2" in *"$3"*"$4"*) echo "  ok   $1" ;; *) echo "  FAIL $1: <$3> is not before <$4> in <$2>"; fail=1 ;; esac
}
lacks() { # desc text part
  case "$2" in *"$3"*) echo "  FAIL $1: <$2> has <$3>"; fail=1 ;; *) echo "  ok   $1" ;; esac
}

T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
log() { :; }
progress() { :; }
sleep() { :; }
# The pull, the config clone and the health check have their own tests.
pull_verified() { return 0; }
build_create_body() { echo '{}'; }
verify() { return "${VERIFY_RC:-0}"; }
RECREATE_NOUN=sidecar

# A fake Engine API: every call is noted in $T/calls, and each step answers what the case sets.
api() {
  echo "$1 $2" >> "$T/calls"
  case "$1 $2" in
    "GET /containers/site1-updater/json")     echo '{"Id":"oldid","Name":"/site1-updater","Config":{"Image":"example.com/argus-updater:latest"},"NetworkSettings":{"Networks":{"bridge":{}}},"HostConfig":{"NetworkMode":"bridge"}}' ;;
    "GET /containers/site1-updater_old/json") printf '%s' "$OLD_JSON" ;;
    "POST /containers/site1-updater/rename?name=site1-updater_old") printf '%s' "$RENAME_OUT" ;;
    "POST /containers/create?name=site1-updater") printf '%s' "$CREATE_OUT" ;;
    "POST /containers/newid/start")           printf '%s' "$START_OUT" ;;
    "DELETE /containers/strayid")             printf '%s' "$UNSTRAY_OUT" ;;
    *) : ;;   # stop, delete, the rollback's rename and start: nothing to say
  esac
}
calls() { tr '\n' ';' < "$T/calls" 2>/dev/null; }
reset() {
  rm -f "$T/calls"
  OLD_JSON='{"message":"No such container: site1-updater_old"}'
  RENAME_OUT=""; CREATE_OUT='{"Id":"newid","Warnings":[]}'; START_OUT=""; UNSTRAY_OUT=""; VERIFY_RC=0
}
run() { recreate_container site1-updater example.com/argus-updater:latest; echo $? > "$T/rc"; }
rc() { cat "$T/rc"; }

echo "api_said: what the Engine said, as one line"
check "nothing said"            "$(api_said '')" ""
check "a refusal's message"     "$(api_said '{"message":"No such image: example.com/x:1"}')" "No such image: example.com/x:1"
check "a result is no refusal"  "$(api_said '{"Id":"abc","Warnings":[]}')" ""
check "curl's own error as is"  "$(api_said 'curl: (7) Failed to connect to the socket')" "curl: (7) Failed to connect to the socket"
check "one line"                "$(api_said "$(printf '{"message":"first line\\nsecond\\tline"}')")" "first line second line"
LONG=$(printf 'x%.0s' $(seq 1 400))
CUT=$(api_said "{\"message\":\"${LONG}the cause comes last\"}")
check "at most 230 characters"  "${#CUT}" 230
has   "its start stays"         "$CUT" "xxxx ... xxxx"
has   "and so does its end"     "$CUT" "xxxxthe cause comes last"
HEX=0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef
check "a container id is cut to 12" "$(api_said "{\"message\":\"Conflict. The container name \\\"/x_old\\\" is already in use by container \\\"$HEX\\\".\"}")" \
  'Conflict. The container name "/x_old" is already in use by container "0123456789ab".'
check "the runtime's wrapping goes" "$(api_said '{"message":"failed to create task for container: failed to create shim task: OCI runtime create failed: runc create failed: unable to start container process: error during container init: exec: \"/no-such-program\": stat /no-such-program: no such file or directory: unknown"}')" \
  'exec: "/no-such-program": stat /no-such-program: no such file or directory'
check "a short refusal is left alone" "$(api_said '{"message":"driver failed programming external connectivity: port is already allocated"}')" \
  "driver failed programming external connectivity: port is already allocated"

echo "image_name: the image at no version"
check "a tag goes"            "$(image_name example.com/x/argus-updater:0.2.27)" "example.com/x/argus-updater"
check "a digest goes"         "$(image_name example.com/x/argus-updater@sha256:abc123)" "example.com/x/argus-updater"
check "tag and digest go"     "$(image_name example.com/x/argus-updater:latest@sha256:abc123)" "example.com/x/argus-updater"
check "a registry port stays" "$(image_name localhost:5000/argus-updater)" "localhost:5000/argus-updater"

echo "a swap that works"
reset; run
check "succeeds" "$(rc)" 0
has   "the old one is parked"  "$(calls)" "POST /containers/site1-updater/rename?name=site1-updater_old"
has   "the new one starts"     "$(calls)" "POST /containers/newid/start"
has   "the old one is dropped" "$(calls)" "DELETE /containers/site1-updater_old?force=true"

echo "a <name>_old left by an update that was cut short: removed, and the update goes on"
reset; OLD_JSON='{"Id":"strayid","Name":"/site1-updater_old","Config":{"Image":"example.com/argus-updater:0.2.26"},"State":{"Status":"exited"}}'; run
check  "succeeds" "$(rc)" 0
before "removed before anything is stopped" "$(calls)" "DELETE /containers/strayid;" "POST /containers/site1-updater/stop"
has    "the old one is parked" "$(calls)" "POST /containers/site1-updater/rename?name=site1-updater_old"
has    "the new one starts"    "$(calls)" "POST /containers/newid/start"

echo "a <name>_old made from the same image and never started: removed too"
reset; OLD_JSON='{"Id":"strayid","Name":"/site1-updater_old","Config":{"Image":"example.com/argus-updater:latest"},"State":{"Status":"created"}}'; run
check  "succeeds" "$(rc)" 0
before "removed before anything is stopped" "$(calls)" "DELETE /containers/strayid;" "POST /containers/site1-updater/stop"

echo "a <name>_old that runs: not ours, refused before anything is stopped"
reset; OLD_JSON='{"Id":"strayid","Name":"/site1-updater_old","Config":{"Image":"example.com/argus-updater:0.2.26"},"State":{"Status":"running"}}'; run
check "fails" "$(rc)" 1
has   "says which container" "$RECREATE_ERR" "a container named site1-updater_old already exists"
has   "says why it stays"    "$RECREATE_ERR" "(it is running)"
has   "says what to do"      "$RECREATE_ERR" "remove or rename it, then update again"
has   "says nothing changed" "$RECREATE_ERR" "the sidecar was left untouched"
lacks "the sidecar is not stopped" "$(calls)" "/stop"
lacks "nothing is renamed"         "$(calls)" "/rename"
lacks "the stray one is not removed" "$(calls)" "DELETE"

echo "a <name>_old from another image: not ours, refused"
reset; OLD_JSON='{"Id":"strayid","Name":"/site1-updater_old","Config":{"Image":"example.com/something-else:1.0"},"State":{"Status":"exited"}}'; run
check "fails" "$(rc)" 1
has   "says why it stays" "$RECREATE_ERR" "(it is from another image, example.com/something-else:1.0)"
lacks "the sidecar is not stopped" "$(calls)" "/stop"
lacks "the stray one is not removed" "$(calls)" "DELETE"

echo "a <name>_old with no image or state told: not ours, refused"
reset; OLD_JSON='{"Id":"strayid","Name":"/site1-updater_old"}'; run
check "fails" "$(rc)" 1
lacks "the sidecar is not stopped" "$(calls)" "/stop"
lacks "the stray one is not removed" "$(calls)" "DELETE"

echo "the Engine refuses to remove the leftover"
reset; OLD_JSON='{"Id":"strayid","Name":"/site1-updater_old","Config":{"Image":"example.com/argus-updater:0.2.26"},"State":{"Status":"exited"}}'
UNSTRAY_OUT='{"message":"removal of container strayid is already in progress"}'; run
check "fails" "$(rc)" 1
has   "names the step"         "$RECREATE_ERR" "could not remove site1-updater_old, left by an earlier update"
has   "carries Docker's words" "$RECREATE_ERR" "(removal of container strayid is already in progress)"
has   "says nothing changed"   "$RECREATE_ERR" "the sidecar was left untouched"
lacks "the sidecar is not stopped" "$(calls)" "/stop"

echo "the Engine refuses the rename"
reset; RENAME_OUT='{"message":"Conflict. The container name \"/site1-updater_old\" is already in use"}'; run
check "fails" "$(rc)" 1
has   "names the step"         "$RECREATE_ERR" "could not rename the old sidecar"
has   "carries Docker's words" "$RECREATE_ERR" 'The container name "/site1-updater_old" is already in use'
has   "the sidecar runs again" "$(calls)" "POST /containers/site1-updater/start"
lacks "no new container"       "$(calls)" "/containers/create"

echo "the Engine refuses the create"
reset; CREATE_OUT='{"message":"No such image: example.com/argus-updater:latest"}'; run
check "fails" "$(rc)" 1
has   "names the step"         "$RECREATE_ERR" "could not create the new sidecar container"
has   "carries Docker's words" "$RECREATE_ERR" "(No such image: example.com/argus-updater:latest)"
has   "rolled back"            "$RECREATE_ERR" "rolled back"
has   "the old name comes back" "$(calls)" "POST /containers/site1-updater_old/rename?name=site1-updater"
has   "the sidecar runs again"  "$(calls)" "POST /containers/site1-updater/start"

echo "a create that answers nothing at all"
reset; CREATE_OUT=''; run
check "fails" "$(rc)" 1
check "says so without an empty bracket" "$RECREATE_ERR" "could not create the new sidecar container - rolled back"

echo "the Engine refuses the start"
reset; START_OUT='{"message":"driver failed programming external connectivity: port is already allocated"}'; run
check "fails" "$(rc)" 1
has   "names the step"         "$RECREATE_ERR" "the new sidecar failed to start"
has   "carries Docker's words" "$RECREATE_ERR" "port is already allocated"
has   "the new one is removed" "$(calls)" "DELETE /containers/newid?force=true"
has   "the old name comes back" "$(calls)" "POST /containers/site1-updater_old/rename?name=site1-updater"
lacks "the old one is not dropped" "$(calls)" "DELETE /containers/site1-updater_old"

echo "a new container that doesn't stay healthy is still rolled back"
reset; VERIFY_RC=1; run
check "fails" "$(rc)" 1
has   "says so"                 "$RECREATE_ERR" "failed its health check, rolled back"
has   "the old name comes back" "$(calls)" "POST /containers/site1-updater_old/rename?name=site1-updater"

if [ "$fail" = 0 ]; then echo "PASS"; else echo "FAILED"; fi
exit $fail
