#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 g-guglielmi
#
# The swap (lib/recreate.sh, recreate_container) against a REAL Docker Engine. The unit test beside
# the sources (deploy/updater/test/swap_test.sh) fakes the Engine API, so it proves what the updater
# does with an answer, not what Docker really answers. This one runs the updater image, in its
# one-shot probe-recreate mode with the Docker socket, against a throwaway container, and looks at
# what Docker holds afterwards:
#   - a swap that works,
#   - a <name>_old left by an earlier update (never started, or stopped) is removed and the swap goes on,
#   - a <name>_old that runs, or is another image, is refused with nothing touched,
#   - a new image Docker cannot start is rolled back, and the reason carries Docker's own words.
# A refused rename and a refused create are not here: with the leftover dealt with up front there is
# no way left to make a real Engine refuse them on purpose. They stay with the unit test.
#
# It needs a Docker Engine it may create containers on, and pulls registry:2 for a registry on
# localhost (the swap pulls its new image, so there has to be somewhere to pull it from). The pull
# request's check runs it against the image it has just built. It lives outside deploy/updater/ so
# that changing it never publishes an image.
#
# Usage: test/swap_live_test.sh UPDATER_IMAGE     (an image already in the local Docker)
set -u
IMG="${1:?usage: swap_live_test.sh UPDATER_IMAGE}"
if ! command -v docker >/dev/null 2>&1 || ! docker info >/dev/null 2>&1; then
  echo "SKIP: no Docker Engine to talk to"; exit 0
fi

PORT="${SWAPTEST_PORT:-5055}"
REPO="localhost:$PORT/swaptest"
T=swaptest                 # the container that gets swapped
REG=swaptest-registry
OTHER=registry:2           # "another image", and the registry itself

fail=0
check() { # desc got want
  if [ "$2" = "$3" ]; then echo "  ok   $1"; else echo "  FAIL $1: got <$2> want <$3>"; fail=1; fi
}
differs() { # desc got unwanted
  if [ "$2" != "$3" ]; then echo "  ok   $1"; else echo "  FAIL $1: still <$2>"; fail=1; fi
}
has() { # desc text part
  case "$2" in *"$3"*) echo "  ok   $1" ;; *) echo "  FAIL $1: the output lacks <$3>"; fail=1 ;; esac
}

cleanup() {
  docker rm -f "$T" "${T}_old" "$REG" swaptest-seed >/dev/null 2>&1
  docker rmi "$REPO:1" "$REPO:2" "$REPO:broken" >/dev/null 2>&1
}
trap cleanup EXIT
cleanup

image()   { docker container inspect -f '{{.Config.Image}}' "$1" 2>/dev/null; }
running() { docker container inspect -f '{{.State.Running}}' "$1" 2>/dev/null; }
state()   { docker container inspect -f '{{.State.Status}}' "$1" 2>/dev/null; }
cid()     { docker container inspect -f '{{.Id}}' "$1" 2>/dev/null; }
there()   { if docker container inspect "$1" >/dev/null 2>&1; then echo yes; else echo no; fi; }

# --- a registry on localhost, and three images in it ---------------------------------------------
# :1 and :2 are the same image under two tags: a container that just stays up (and ends at once on
# the stop the swap sends). :broken starts a program that isn't there, so Docker refuses to start it.
# They are made from the updater image itself, so nothing else has to be pulled or built.
echo "setting up: a registry on localhost:$PORT and the test images"
docker run -d --name "$REG" -p "127.0.0.1:$PORT:5000" "$OTHER" >/dev/null || { echo "FAILED: could not start a local registry"; exit 1; }
for _ in $(seq 1 30); do curl -sf "http://127.0.0.1:$PORT/v2/" >/dev/null 2>&1 && break; sleep 1; done
docker create --name swaptest-seed --no-healthcheck --entrypoint sh "$IMG" >/dev/null || { echo "FAILED: could not create a container from $IMG"; exit 1; }
docker commit --change "ENTRYPOINT [\"sh\",\"-c\",\"trap 'exit 0' TERM; while :; do sleep 1; done\"]" swaptest-seed "$REPO:1" >/dev/null \
  && docker tag "$REPO:1" "$REPO:2" \
  && docker commit --change 'ENTRYPOINT ["/swaptest-no-such-program"]' swaptest-seed "$REPO:broken" >/dev/null \
  || { echo "FAILED: could not make the test images"; exit 1; }
docker rm swaptest-seed >/dev/null
for _t in 1 2 broken; do
  docker push -q "$REPO:$_t" >/dev/null || { echo "FAILED: could not push $REPO:$_t to the local registry"; exit 1; }
done

# fresh - the container to swap, running :1 again, and no <name>_old.
fresh() {
  docker rm -f "$T" "${T}_old" >/dev/null 2>&1
  docker run -d --name "$T" "$REPO:1" >/dev/null
  ID0=$(cid "$T")
}
# swap TAG - what a sidecar does to update itself: the updater image, one-shot, against $T. The
# images here are signed by nobody, so the signature check is off; the health check is kept short.
swap() {
  OUT=$(docker run --rm -v /var/run/docker.sock:/var/run/docker.sock \
    -e ARGUS_UPDATER_MODE=probe-recreate -e ARGUS_RECREATE_TARGET="$T" -e ARGUS_RECREATE_TAG="$1" \
    -e ARGUS_VERIFY_SIGNATURES=0 -e ARGUS_HEALTH_STABLE=3 "$IMG" 2>&1)
  RC=$?
  printf '%s\n' "$OUT" | sed 's/^/    | /'
}
untouched() {
  check "the container is the same one" "$(cid "$T")" "$ID0"
  check "it still runs"                 "$(running "$T")" true
  check "on the image it had"           "$(image "$T")" "$REPO:1"
}

echo "a swap that works"
fresh; swap 2
check   "the updater says it worked" "$RC" 0
check   "it runs the new image"      "$(image "$T")" "$REPO:2"
check   "it runs"                    "$(running "$T")" true
differs "it is a new container"      "$(cid "$T")" "$ID0"
check   "no ${T}_old stays behind"   "$(there "${T}_old")" no

echo "a ${T}_old made from the same image and never started: removed, and the swap goes on"
fresh; docker create --name "${T}_old" "$REPO:1" >/dev/null; swap 2
check "the updater says it worked" "$RC" 0
has   "it says what it removed"    "$OUT" "removed ${T}_old, left by an earlier update"
check "it runs the new image"      "$(image "$T")" "$REPO:2"
check "it runs"                    "$(running "$T")" true
check "no ${T}_old stays behind"   "$(there "${T}_old")" no

echo "a ${T}_old that ran and was stopped: removed too"
fresh; docker run -d --name "${T}_old" "$REPO:1" >/dev/null; docker stop "${T}_old" >/dev/null; WAS=$(state "${T}_old"); swap 2
check "the leftover had stopped"   "$WAS" exited
check "the updater says it worked" "$RC" 0
check "it runs the new image"      "$(image "$T")" "$REPO:2"
check "no ${T}_old stays behind"   "$(there "${T}_old")" no

echo "a ${T}_old that runs: refused, nothing touched"
fresh; docker run -d --name "${T}_old" "$REPO:1" >/dev/null; OLDID=$(cid "${T}_old"); swap 2
check "the updater says it failed" "$RC" 1
has   "it says why"                "$OUT" "a container named ${T}_old already exists and is not what an update leaves behind (it is running)"
has   "it says what to do"         "$OUT" "remove or rename it, then update again"
untouched
check "the other one is still there" "$(cid "${T}_old")" "$OLDID"
check "and still runs"               "$(running "${T}_old")" true

echo "a ${T}_old from another image: refused, nothing touched"
fresh; docker create --name "${T}_old" "$OTHER" >/dev/null; OLDID=$(cid "${T}_old"); swap 2
check "the updater says it failed" "$RC" 1
has   "it says why"                "$OUT" "(it is from another image, $OTHER)"
untouched
check "the other one is still there" "$(cid "${T}_old")" "$OLDID"

echo "a new image Docker cannot start: rolled back, with Docker's own words"
fresh; swap broken
check "the updater says it failed" "$RC" 1
has   "it names the step"          "$OUT" "the new container failed to start ("
has   "it says it rolled back"     "$OUT" "- rolled back"
has   "Docker's words name the program that isn't there" "$(printf '%s\n' "$OUT" | grep 'failed to start (' | tail -n1)" "swaptest-no-such-program"
untouched
check "no ${T}_old stays behind"   "$(there "${T}_old")" no

# --- a swap that was cut short ---------------------------------------------------------------
# The state a power cut leaves is made by hand, with the note the swap would have left (the
# container's real id); then the updater's own swap_heal runs against the real Engine.
# heal NOTED_ID - sets OUT to what it logged and said.
heal() {
  OUT=$(docker run --rm -v /var/run/docker.sock:/var/run/docker.sock -e NOTED="$1" -e T="$T" -e TO="$REPO:2" \
    --entrypoint sh "$IMG" -c '
      . /usr/local/lib/argus-updater/lib/recreate.sh
      log() { echo "argus-updater[test]: $*"; }
      swap_mark "$T" "$NOTED" "$TO"
      swap_heal
      echo "HEALED=$HEALED BACK=$HEAL_BACK"
      if [ -f "$SWAP_MARK" ]; then echo "NOTE=there"; else echo "NOTE=gone"; fi
    ' 2>&1)
  printf '%s\n' "$OUT" | sed 's/^/    | /'
}
back() {
  has   "it says it put the container back" "$OUT" "the previous container was put back and runs again"
  has   "healed, and the note is gone"      "$OUT" "HEALED=1 BACK=1"
  has   "the note is gone"                  "$OUT" "NOTE=gone"
  untouched
  check "no ${T}_old stays behind"          "$(there "${T}_old")" no
}

echo "cut before the rename (the container stopped, still under its name): started again"
fresh; docker stop "$T" >/dev/null; heal "$ID0"
back

echo "cut after the rename (the container parked, nothing under its name): its name back, started"
fresh; docker stop "$T" >/dev/null; docker rename "$T" "${T}_old"; heal "$ID0"
back

echo "cut after the create (the new one never started): the new one goes, the old one is back"
fresh; docker stop "$T" >/dev/null; docker rename "$T" "${T}_old"; docker create --name "$T" "$REPO:2" >/dev/null; heal "$ID0"
back

echo "cut during the health check (the new one runs, unchecked): the new one goes, the old one is back"
fresh; docker stop "$T" >/dev/null; docker rename "$T" "${T}_old"; docker run -d --name "$T" "$REPO:2" >/dev/null; heal "$ID0"
back

echo "the swap had ended and only the note stayed: nothing changes"
fresh; heal 0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef
has   "nothing to tell"   "$OUT" "HEALED=0"
has   "the note is gone"  "$OUT" "NOTE=gone"
untouched

if [ "$fail" = 0 ]; then echo "PASS"; else echo "FAILED"; fi
exit $fail
