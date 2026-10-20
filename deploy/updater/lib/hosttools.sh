# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 g-guglielmi

# shellcheck shell=sh
# argus-updater - the core host's scripts and units (core mode).
#
# The core VM's host side (the OS reporter, the reboot, patch and Zabbix watchers, the timezone check,
# the sizing tool, the backup tools, their systemd units) lives on the host, which no container update
# reaches by itself. The Argus image carries them (/host-tools, labelled io.argus.host-tools, with a
# manifest) and writes the ones that changed with `/argus install-host-tools`. We hold the socket, so
# we run that very image once - as root, no network, the host's /usr/local/sbin and
# /etc/systemd/system bound under /host and the shared dir at /update - and write the outcome to
# host-tools.json in the shared dir for the Updates page. A container cannot reload systemd: when a
# unit changed the install drops host-tools-apply.json in the shared dir, and argus-host-tools.path
# on the host does the reload. Nobody re-runs an installer by hand.
#
# Only a host set up as a core gets this: the reporter's os-status.json in the shared dir is the sign
# (setup-core.sh or setup-core-patching.sh ran there once). Argus as a container on another kind of
# host (Unraid, a Docker host with Zabbix elsewhere) is skipped, and so is an image without the label.
#
# When: the core's image changed since the last run, a day after a success (puts back a deleted or
# edited script), ten minutes after a failure. Same rhythm as the collectors.
#
# Needs from the caller: api, resolve_core, now, log; UPDATE_DIR.

HOST_TOOLS_FILE="${UPDATE_DIR:-/update}/host-tools.json"
HT_IMG=""     # the core image id the last run was for
HT_STATE=""   # ok | failed | skipped
HT_AT=0       # when it ran (epoch seconds)

# host_update_dir - the host path of our /update mount (the units carry it): the configured value,
# else the Source of our own container's mount at /update.
host_update_dir() {
  if [ -n "${ARGUS_HOST_UPDATE_DIR:-}" ]; then echo "$ARGUS_HOST_UPDATE_DIR"; return 0; fi
  api GET "/containers/$(hostname)/json" 2>/dev/null \
    | jq -r '.Mounts[]? | select(.Destination == "/update") | .Source // empty' 2>/dev/null | head -n1
}

# write_host_tools STATE MESSAGE [SUMMARY_JSON] - atomic, so the core never reads half a file.
write_host_tools() {
  _sum="${3:-}"
  printf '%s' "$_sum" | jq -e 'type == "object"' >/dev/null 2>&1 || _sum='{}'
  jq -nc --arg s "$1" --arg m "$2" --arg at "$(now)" --arg img "$HT_IMG" --argjson sum "$_sum" \
     '{state:$s, at:$at, image:$img} + (if $m == "" then {} else {message:$m} end)
      + ($sum | {version, installed, units_changed, apply} | with_entries(select(.value != null)))' \
     > "$HOST_TOOLS_FILE.tmp" 2>/dev/null && mv "$HOST_TOOLS_FILE.tmp" "$HOST_TOOLS_FILE" 2>/dev/null || true
}

# host_tools_due IMAGE_ID NOW - whether to (re)install now.
host_tools_due() {
  [ "$1" != "$HT_IMG" ] && return 0
  case "$HT_STATE" in
    ok)     [ $(($2 - HT_AT)) -ge 86400 ] ;;
    failed) [ $(($2 - HT_AT)) -ge 600 ] ;;
    *)      return 1 ;;   # skipped: nothing changes until the image does
  esac
}

# sync_host_tools - one round: install the running core image's host tools when due.
sync_host_tools() {
  _hname=$(resolve_core 2>/dev/null || true)
  [ -z "$_hname" ] && return 0
  _himg=$(api GET "/containers/$_hname/json" 2>/dev/null | jq -r '.Image // empty' 2>/dev/null || true)
  [ -z "$_himg" ] && return 0
  _hnow=$(epoch)
  host_tools_due "$_himg" "$_hnow" || return 0
  HT_IMG="$_himg"; HT_AT="$_hnow"
  if [ ! -f "${UPDATE_DIR:-/update}/os-status.json" ]; then
    HT_STATE=skipped
    write_host_tools skipped "this host was not set up as an Argus core (no host reporter): nothing to keep current here"
    return 0
  fi
  _hlabel=$(api GET "/images/$_himg/json" 2>/dev/null | jq -r '.Config.Labels["io.argus.host-tools"] // empty' 2>/dev/null || true)
  if [ -z "$_hlabel" ]; then
    HT_STATE=skipped
    write_host_tools skipped "this Argus version doesn't carry its host tools yet; they come with the next update"
    return 0
  fi
  _hdir=$(host_update_dir)
  if [ -z "$_hdir" ]; then
    HT_STATE=failed
    write_host_tools failed "could not tell the host path of the shared dir (set ARGUS_HOST_UPDATE_DIR on the sidecar)"
    return 0
  fi
  _hout=$(docker run --rm --network none --user 0:0 --read-only --cap-drop ALL \
            --cap-add DAC_OVERRIDE --cap-add FOWNER --cap-add CHOWN \
            --mount "type=bind,src=/usr/local/sbin,dst=/host/usr/local/sbin" \
            --mount "type=bind,src=/etc/systemd/system,dst=/host/etc/systemd/system" \
            --mount "type=bind,src=$_hdir,dst=/update" \
            --entrypoint /argus "$_himg" install-host-tools --root /host --state-dir "$_hdir" --update-dir /update 2>&1) && _hrc=0 || _hrc=$?
  if [ "$_hrc" -eq 0 ]; then
    HT_STATE=ok
    _hsum=$(printf '%s\n' "$_hout" | tail -n 1)
    write_host_tools ok "" "$_hsum"
    _hn=$(printf '%s' "$_hsum" | jq -r '(.installed // []) | length' 2>/dev/null || echo 0)
    if [ "$_hn" != "0" ]; then log "installed $_hn host tool file(s); $(printf '%s' "$_hsum" | jq -r 'if .apply then "the host reloads systemd" else "no unit changed" end' 2>/dev/null)"; fi
  elif printf '%s' "$_hout" | grep -qi 'bind source path does not exist'; then
    HT_STATE=skipped
    write_host_tools skipped "this host has no /etc/systemd/system or /usr/local/sbin to install into (not a core VM)"
  else
    HT_STATE=failed
    _hmsg=$(printf '%s' "$_hout" | sed 's/^argus install-host-tools: //' | tr '\n' ' ' | sed 's/ *$//' | cut -c1-200)
    write_host_tools failed "$_hmsg"
    log "installing the host tools failed: $_hmsg"
  fi
  return 0
}
