# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 g-guglielmi

# shellcheck shell=sh
# argus-updater shared recreate engine.
#
# The one copy of "recreate a container on a new image via the Docker Engine API" used by every mode
# (the core watcher, the probe one-shot recreate). It clones the running container's config
# (Binds/Mounts, env, restart policy, network, labels, ports) and swaps ONLY the image tag, so
# whatever flags the operator deployed with survive an update.
#
# Safety: the old container is stopped and renamed (not removed) first, and restored if the new one
# fails to create, start, OR stay up (a crash-looping bad image is rolled back too) - so a bad
# pull/create/build never leaves you without the target running.
#
# The caller must define two hooks before calling recreate_container:
#   progress MSG   - report an in-progress step (core -> status.json; probe -> stdout)
#   log MSG        - a plain log line
# and may set:
#   RECREATE_NOUN        - human noun for messages (default "container"); e.g. "core"
#   ARGUS_VERIFY_HEALTHZ - "1" to also accept a passing HTTP /healthz as healthy (core); else
#                          stability-only (an active Zabbix proxy has no HTTP endpoint to probe)
#   ARGUS_HEALTH_STABLE  - seconds the new container must stay up to pass (default 20)
#   ARGUS_VERIFY_TIMEOUT - give up (and roll back) after this long (default 90)
#
# recreate_container NAME NEW_IMAGE -> 0 on success; 1 on failure with RECREATE_ERR set to the
# reason (already rolled back to the previous container).

SOCK=/var/run/docker.sock

# heartbeat MAX_AGE - tell the container healthcheck (/app/healthcheck.sh) that the watch loop is
# still going round: now, and how long the next round may take before it counts as stuck.
heartbeat() {
  _hb="${ARGUS_HEARTBEAT_FILE:-/tmp/argus-updater.heartbeat}"
  # Written aside and renamed, so the healthcheck never reads a half-written file.
  printf '%s %s\n' "$(date +%s)" "$1" > "$_hb.new" 2>/dev/null && mv -f "$_hb.new" "$_hb" 2>/dev/null || true
}

RECREATE_NOUN="${RECREATE_NOUN:-container}"
HEALTH_STABLE="${ARGUS_HEALTH_STABLE:-20}"
VERIFY_TIMEOUT="${ARGUS_VERIFY_TIMEOUT:-90}"

# api METHOD PATH [BODY] - talk to the Docker Engine API over the unix socket.
api() {
  if [ "$#" -ge 3 ]; then
    curl -sS --unix-socket "$SOCK" -X "$1" -H 'Content-Type: application/json' -d "$3" "http://localhost$2"
  else
    curl -sS --unix-socket "$SOCK" -X "$1" "http://localhost$2"
  fi
}

# self_container_id - THIS container's own id, resolved robustly. /etc/hostname is NOT reliable (it
# can be a custom hostname, or inherited from another container when a network namespace is shared).
# Docker bind-mounts this container's config files (hostname/hosts/resolv.conf) from
# /var/lib/docker/containers/<full-id>/... , so that id is visible in /proc/self/mountinfo regardless
# of the hostname. Fall back to /etc/hostname only if that fails.
self_container_id() {
  _cid=$(grep -oE 'containers/[0-9a-f]{64}' /proc/self/mountinfo 2>/dev/null | head -n1 | grep -oE '[0-9a-f]{64}')
  [ -z "$_cid" ] && _cid=$(cat /etc/hostname 2>/dev/null)
  printf '%s' "$_cid"
}

# image_repo IMAGE - strip the tag, keep the repo (ghcr.io/x/y:tag -> ghcr.io/x/y).
image_repo() { printf '%s' "$1" | sed 's/:[^:/]*$//'; }
# image_tag IMAGE - the tag (ghcr.io/x/y:tag -> tag; empty if none).
image_tag()  { printf '%s' "$1" | sed -n 's#.*:\([^:/]*\)$#\1#p'; }

# valid_tag TAG - an image tag we would pull: what the core hands out is checked before it becomes
# an image reference (letters, digits, dot, underscore, hyphen; no leading punctuation; <= 64).
valid_tag() {
  case "$1" in ''|*[!A-Za-z0-9._-]*|[._-]*) return 1;; esac
  [ "${#1}" -le 64 ]
}

# valid_digest DIGEST - the shape of a content digest the core hands out with a tag.
valid_digest() {
  [ "${#1}" -eq 71 ] || return 1
  case "$1" in sha256:*) ;; *) return 1;; esac
  case "${1#sha256:}" in *[!a-f0-9]*) return 1;; esac
  return 0
}

# --- image signatures ---------------------------------------------------------------------------
# Every Argus image is signed keyless (Sigstore) by the workflow that built it: the signature names
# that workflow and sits in the public transparency log, so a pull can prove the image came from
# the build and not from someone holding a registry token. sig_identity says which workflow may
# have built an image repository; verify_signature runs cosign against the pulled digest.
#   ARGUS_VERIFY_SIGNATURES=0  take an image on its digest alone (a site with no route to Sigstore's
#                              public trust root); the default is to verify.
#   ARGUS_SIGNING_IDENTITY     the certificate identity regexp to expect instead of ours (a fork
#                              that builds its own images).
SIG_ISSUER="https://token.actions.githubusercontent.com"

# sig_identity REPO - the certificate identity regexp of the workflow allowed to have built REPO
# (ghcr.io/<owner>/<name>); 1 when the name is none of ours.
sig_identity() {
  if [ -n "${ARGUS_SIGNING_IDENTITY:-}" ]; then printf '%s' "$ARGUS_SIGNING_IDENTITY"; return 0; fi
  _owner=$(printf '%s' "$1" | awk -F/ 'NF>=3{print $2}')
  _name=$(printf '%s' "$1" | awk -F/ '{print $NF}')
  [ -n "$_owner" ] || return 1
  case "$_name" in
    argus)         _src="argus-core/.github/workflows/build.yml" ;;
    argus-probe)   _src="argus-probe/.github/workflows/probe-image.yml" ;;
    argus-updater) _src="argus-updater/.github/workflows/updater-image.yml" ;;
    *) return 1 ;;
  esac
  printf '^https://github.com/%s/%s@' "$_owner" "$_src"
}

# verify_signature REPO DIGEST - cosign verify of REPO@DIGEST against the workflow allowed to have
# built it. 0 when verified (or when verification is off); 1 with VERIFY_ERR set otherwise.
verify_signature() {
  VERIFY_ERR=""
  if [ "${ARGUS_VERIFY_SIGNATURES:-1}" = "0" ]; then
    log "signature check off (ARGUS_VERIFY_SIGNATURES=0): $1@$2 taken on its digest alone"
    return 0
  fi
  if ! _id=$(sig_identity "$1"); then
    VERIFY_ERR="no build is known to sign images named $1; refusing it (ARGUS_SIGNING_IDENTITY names the signer of a fork's images)"
    return 1
  fi
  if ! command -v cosign >/dev/null 2>&1; then
    VERIFY_ERR="cosign is missing from this updater image; cannot verify $1@$2"
    return 1
  fi
  if _out=$(timeout 180 cosign verify --certificate-oidc-issuer "$SIG_ISSUER" --certificate-identity-regexp "$_id" "$1@$2" 2>&1 >/dev/null); then
    log "$1@$2 signature verified: built by $(printf '%s' "$_id" | sed 's/^^//; s/@$//')"
    return 0
  fi
  VERIFY_ERR="$1@$2 is not signed by its build ($(printf '%s' "$_out" | tail -n1 | cut -c1-160)); refusing to run it"
  return 1
}

# pull_verified IMAGE [DIGEST] - docker pull with retries, then two checks before the image may run.
# First the digest: when one was handed out with the tag (what the core saw the tag point to), the
# pulled image's repository digest must be it, so an image swapped under the tag in between is
# refused; without one, the pulled digest is taken as is. Then the signature of that digest
# (verify_signature): the image must have been signed by the workflow allowed to build it. Tags stay
# tags (latest, testing, a version). Returns 1 with PULL_ERR set on failure.
pull_verified() {
  _img="$1"; _want="${2:-}"
  PULL_ERR=""
  _pn=1
  until docker pull "$_img"; do
    if [ "$_pn" -ge 3 ]; then PULL_ERR="pull of $_img failed after 3 attempts"; return 1; fi
    log "pull attempt $_pn failed; retrying in 5s"
    _pn=$(( _pn + 1 ))
    sleep 5
  done
  _repo=$(image_repo "$_img")
  if [ -n "$_want" ]; then
    if ! valid_digest "$_want"; then PULL_ERR="the digest handed out for $_img is malformed"; return 1; fi
    if ! api GET "/images/$_img/json" | jq -e --arg d "$_repo@$_want" '.RepoDigests // [] | index($d) != null' >/dev/null 2>&1; then
      _got=$(api GET "/images/$_img/json" | jq -r '(.RepoDigests // []) | join(", ")' 2>/dev/null || true)
      PULL_ERR="the image pulled for $_img ($_got) is not the one the core handed out ($_want); refusing to run it"
      return 1
    fi
    log "$_img verified: $_want"
    _have="$_want"
  else
    if [ "${ARGUS_VERIFY_SIGNATURES:-1}" = "0" ]; then
      log "no digest was handed out for $_img; applying the tag unverified"
      return 0
    fi
    _have=$(api GET "/images/$_img/json" | jq -r --arg r "$_repo@" '(.RepoDigests // [])[] | select(startswith($r)) | sub("^.*@"; "")' 2>/dev/null | head -n1)
    if ! valid_digest "$_have"; then PULL_ERR="could not read the digest of the pulled $_img, so its signature can't be checked"; return 1; fi
    log "no digest was handed out for $_img; the pulled one is $_have"
  fi
  if ! verify_signature "$_repo" "$_have"; then PULL_ERR="$VERIFY_ERR"; return 1; fi
  return 0
}

# read_kv FILE KEY - one value from a KEY=VALUE file, read as data (the file is never sourced: its
# values arrive over the network and would otherwise run as shell, here with the Docker socket).
read_kv() { [ -f "$1" ] && sed -n "s/^$2=//p" "$1" | head -n1; }

# verify NAME - return 0 once the container looks healthy: it stays Running and not Restarting for
# HEALTH_STABLE seconds (a crash-loop guard - a bad image that starts then exits never reaches a
# stable window). When ARGUS_VERIFY_HEALTHZ=1 and the container has an IP on a shared network, a
# passing GET :8080/healthz short-circuits to healthy. Return 1 on timeout.
verify() {
  _name="$1"
  sleep 5   # brief grace for startup
  _need=$(( HEALTH_STABLE / 3 )); [ "$_need" -lt 1 ] && _need=1
  _stable=0
  _end=$(( $(date +%s) + VERIFY_TIMEOUT ))
  while [ "$(date +%s)" -lt "$_end" ]; do
    _json=$(api GET "/containers/$_name/json")
    _running=$(printf '%s' "$_json" | jq -r '.State.Running // false')
    _restarting=$(printf '%s' "$_json" | jq -r '.State.Restarting // false')
    if [ "$_running" != "true" ] || [ "$_restarting" = "true" ]; then
      _stable=0; sleep 3; continue
    fi
    if [ "${ARGUS_VERIFY_HEALTHZ:-0}" = "1" ]; then
      _ip=$(printf '%s' "$_json" | jq -r '[.NetworkSettings.Networks[]?.IPAddress] | map(select(. != "" and . != null)) | .[0] // empty')
      if [ -n "$_ip" ] && curl -sf -m 3 "http://$_ip:8080/healthz" >/dev/null 2>&1; then
        return 0
      fi
    fi
    _stable=$(( _stable + 1 ))
    [ "$_stable" -ge "$_need" ] && return 0
    sleep 3
  done
  return 1
}

# --- container config cloning (pure: take the inspect JSON, emit request bodies; unit-tested) ---

# user_nets INSPECT -> the user-defined networks the container is attached to, one per line. The
# default bridge / host / none pseudo-networks carry no preservable endpoint config (static IP / MAC
# / aliases) and are handled by HostConfig.NetworkMode, so they are excluded here.
user_nets() {
  printf '%s' "$1" | jq -r '(.NetworkSettings.Networks // {}) | keys[]?
    | select(test("^(default|bridge|host|none)$") | not)'
}

# primary_net INSPECT -> the network attached at create time: HostConfig.NetworkMode when it names a
# user-defined network the container is on, else the first user network (empty if none).
primary_net() {
  _nm=$(printf '%s' "$1" | jq -r '.HostConfig.NetworkMode // "default"')
  _un=$(user_nets "$1")
  if printf '%s\n' "$_un" | grep -Fxq -- "$_nm"; then printf '%s' "$_nm"; else printf '%s\n' "$_un" | head -n1; fi
}

# endpoint_cfg INSPECT NET -> the create-time EndpointConfig for one network: only operator-set /
# stable fields (static IP, MAC, aliases, links, driver opts); runtime state (the assigned IPAddress,
# gateway, ids) is stripped so Docker accepts it.
endpoint_cfg() {
  printf '%s' "$1" | jq --arg n "$2" '
    .NetworkSettings.Networks[$n] as $e
    | {
        IPAMConfig: ($e.IPAMConfig | if type == "object" then with_entries(select(.value != null and .value != "")) else null end),
        Aliases: $e.Aliases, MacAddress: $e.MacAddress, Links: $e.Links, DriverOpts: $e.DriverOpts
      }
    | with_entries(select(.value != null and .value != "" and .value != [] and .value != {}))'
}

# build_create_body NEW_IMAGE INSPECT -> the POST /containers/create body: the running container's
# config with only the image swapped. Keeps operator Env/Labels/ExposedPorts and the whole HostConfig
# (binds/mounts, restart policy, ports); preserves an operator-set Hostname/Domainname and the primary
# network's endpoint - the static IP / MAC / aliases live in NetworkSettings.Networks, NOT HostConfig,
# so a plain clone loses them (extra networks are connected after create). An AUTO hostname (Docker
# sets it to the short id when the operator gave none: Config.Hostname == Id[0:12]) is dropped so the
# new container gets its own id, which the updater's self-update wants.
build_create_body() {
  _img="$1"; _ins="$2"
  _prim=$(primary_net "$_ins")
  _net=null
  if [ -n "$_prim" ]; then
    _net=$(jq -n --arg n "$_prim" --argjson ep "$(endpoint_cfg "$_ins" "$_prim")" '{EndpointsConfig: {($n): $ep}}')
  fi
  printf '%s' "$_ins" | jq --arg img "$_img" --argjson net "$_net" '
    {
      Image: $img,
      Env: .Config.Env,
      Labels: (.Config.Labels // {}),
      ExposedPorts: .Config.ExposedPorts,
      HostConfig: .HostConfig
    }
    + (if (.Config.Hostname // "") != "" and (.Config.Hostname != (.Id[0:12])) then {Hostname: .Config.Hostname} else {} end)
    + (if (.Config.Domainname // "") != "" then {Domainname: .Config.Domainname} else {} end)
    + (if $net != null then {NetworkingConfig: $net} else {} end)'
}

# recreate_container NAME NEW_IMAGE [DIGEST] - the full pull -> clone-config recreate -> verify ->
# rollback dance. Returns 0 on success, or 1 with RECREATE_ERR set (and the previous container
# restored). With a DIGEST, the pull must resolve to it (see pull_verified).
recreate_container() {
  NAME="$1"; NEW_IMAGE="$2"; EXPECT_DIGEST="${3:-}"
  if ! valid_tag "$(image_tag "$NEW_IMAGE")"; then
    RECREATE_ERR="refusing image reference '$NEW_IMAGE': not a valid tag"
    return 1
  fi
  RECREATE_ERR=""

  INSPECT=$(api GET "/containers/$NAME/json")
  CUR_IMAGE=$(printf '%s' "$INSPECT" | jq -r '.Config.Image // empty')
  if [ -z "$CUR_IMAGE" ]; then
    RECREATE_ERR="could not inspect the $RECREATE_NOUN container '$NAME'"
    return 1
  fi
  log "$NAME  $CUR_IMAGE -> $NEW_IMAGE"

  # Pull with a few retries, then verify the digest when one was handed out: a transient registry
  # blip must not silently no-op the update, and a swapped image must not run (the pull happens
  # BEFORE we touch the container, so a failure here leaves it running untouched).
  progress "pulling $NEW_IMAGE"
  if ! pull_verified "$NEW_IMAGE" "$EXPECT_DIGEST"; then
    RECREATE_ERR="$PULL_ERR - the $RECREATE_NOUN was left untouched"
    log "$RECREATE_ERR"
    return 1
  fi

  # Clone the running config, swapping only the image (see build_create_body: preserves the network
  # endpoint's static IP / MAC / aliases and an operator hostname, which a plain HostConfig clone drops).
  CREATE_BODY=$(build_create_body "$NEW_IMAGE" "$INSPECT")

  rollback() {
    log "rolling back to the previous $RECREATE_NOUN"
    api POST "/containers/${NAME}_old/rename?name=$NAME" >/dev/null 2>&1 || true
    api POST "/containers/$NAME/start" >/dev/null 2>&1 || true
  }

  progress "recreating $NAME on $NEW_IMAGE"
  api POST "/containers/$NAME/stop?t=15" >/dev/null 2>&1 || true
  if ! api POST "/containers/$NAME/rename?name=${NAME}_old" >/dev/null 2>&1; then
    api POST "/containers/$NAME/start" >/dev/null 2>&1 || true
    RECREATE_ERR="could not rename the old $RECREATE_NOUN - aborted, $RECREATE_NOUN left running"
    return 1
  fi

  NEWID=$(api POST "/containers/create?name=$NAME" "$CREATE_BODY" | jq -r '.Id // empty')
  if [ -z "$NEWID" ]; then
    rollback
    RECREATE_ERR="could not create the new $RECREATE_NOUN container - rolled back"
    return 1
  fi

  # Attach any ADDITIONAL user networks (create only attached the primary), each with its own
  # preserved endpoint (static IP / MAC / aliases). Connect while still stopped so the container
  # starts already on every network. A failed connect rolls back rather than start half-networked.
  _primary=$(primary_net "$INSPECT")
  for _n in $(user_nets "$INSPECT"); do
    [ "$_n" = "$_primary" ] && continue
    _body=$(jq -n --arg c "$NEWID" --argjson ep "$(endpoint_cfg "$INSPECT" "$_n")" '{Container: $c, EndpointConfig: $ep}')
    _err=$(api POST "/networks/$_n/connect" "$_body" | jq -r '.message // empty')
    if [ -n "$_err" ]; then
      api DELETE "/containers/$NEWID?force=true" >/dev/null 2>&1 || true
      rollback
      RECREATE_ERR="could not attach the new $RECREATE_NOUN to network '$_n' ($_err) - rolled back"
      return 1
    fi
  done

  if ! api POST "/containers/$NEWID/start" >/dev/null 2>&1; then
    api DELETE "/containers/$NEWID?force=true" >/dev/null 2>&1 || true
    rollback
    RECREATE_ERR="the new $RECREATE_NOUN failed to start - rolled back"
    return 1
  fi

  progress "verifying the new $RECREATE_NOUN is healthy"
  if ! verify "$NAME"; then
    api POST "/containers/$NAME/stop?t=10" >/dev/null 2>&1 || true
    api DELETE "/containers/$NAME?force=true" >/dev/null 2>&1 || true
    rollback
    RECREATE_ERR="the new $RECREATE_NOUN did not become healthy in time - rolled back to the previous version"
    log "verify failed - rolled back"
    return 1
  fi

  # Success - drop the old container.
  api DELETE "/containers/${NAME}_old?force=true" >/dev/null 2>&1 || true
  log "$NAME updated to $NEW_IMAGE"
  return 0
}
