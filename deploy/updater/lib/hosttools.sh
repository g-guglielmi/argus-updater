# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 g-guglielmi

# shellcheck shell=sh
# argus-updater - the host's scripts and units (core mode and probe-watch mode).
#
# A VM's host side (the OS reporter, the console menu, the core's reboot, patch and Zabbix watchers,
# the sizing and backup tools, their systemd units) lives on the host, which no container update
# reaches by itself. The Argus image and the probe image each carry their host's files (/host-tools,
# labelled io.argus.host-tools, with a manifest) and an installer that writes the ones that changed:
# `/argus install-host-tools` in the core image, `python3 /host-tools/install-host-tools.py` in the
# probe image. We hold the socket, so we run that very image once - as root, no network, the host's
# /usr/local/sbin and /etc/systemd/system bound under /host and the host's state folder at /update -
# and record the outcome in host-tools.json in that folder (the Updates page and the console menu
# read it) and, on a probe, in our own check-in with Argus. A container cannot reload systemd: when a
# unit changed the install drops host-tools-apply.json in the folder, and argus-host-tools.path on the
# host does the reload. Nobody re-runs an installer by hand.
#
# Only a host set up for it gets this. On a core, the reporter's os-status.json in the shared dir is
# the sign (setup-core.sh or setup-core-patching.sh ran there once); on a probe, host-tools.json in
# the probe's data folder is (the VM image wrote it at build). Argus or a probe as a container on
# another kind of host (Unraid, a Docker host with Zabbix elsewhere) is skipped, and so is an image
# without the label.
#
# When: the managed image changed since the last run, a day after a success (puts back a deleted or
# edited script), ten minutes after a failure. Same rhythm as the collectors.
#
# Needs from the caller: api, log; resolve_core (core) or resolve_proxy (probe); HT_ROLE=core|probe
# (default core); UPDATE_DIR (core) or PROBE_DIR (probe, default /probe, our read-only mount).

HT_ROLE="${HT_ROLE:-core}"
HOST_TOOLS_FILE="${UPDATE_DIR:-/update}/host-tools.json"
HT_IMG=""     # the managed image id the last run was for
HT_STATE=""   # ok | failed | skipped
HT_AT=0       # when it ran (epoch seconds)
HT_DIR=""     # the host path of the state folder
HT_DOC=""     # the last status document (JSON), for the probe's check-in
command -v epoch >/dev/null 2>&1 || epoch() { date +%s; }
command -v now >/dev/null 2>&1 || now() { date -u +%Y-%m-%dT%H:%M:%SZ; }

# host_update_dir - the host path of our /update mount (the core's units carry it): the configured
# value, else the Source of our own container's mount at /update.
host_update_dir() {
  if [ -n "${ARGUS_HOST_UPDATE_DIR:-}" ]; then echo "$ARGUS_HOST_UPDATE_DIR"; return 0; fi
  api GET "/containers/$(hostname)/json" 2>/dev/null \
    | jq -r '.Mounts[]? | select(.Destination == "/update") | .Source // empty' 2>/dev/null | head -n1
}

# host_probe_dir - the host path of the probe's data folder, our read-only /probe mount: the
# configured value, else that mount's Source.
host_probe_dir() {
  if [ -n "${ARGUS_HOST_PROBE_DIR:-}" ]; then echo "$ARGUS_HOST_PROBE_DIR"; return 0; fi
  api GET "/containers/$(hostname)/json" 2>/dev/null \
    | jq -r --arg d "${PROBE_DIR:-/probe}" '.Mounts[]? | select(.Destination == $d) | .Source // empty' 2>/dev/null | head -n1
}

# ht_doc STATE MESSAGE SUMMARY_JSON - the status document, one shape for the file and the check-in.
ht_doc() {
  jq -nc --arg s "$1" --arg m "$2" --arg at "$(now)" --arg img "$HT_IMG" --argjson sum "$3" \
     '{state:$s, at:$at, image:$img} + (if $m == "" then {} else {message:$m} end)
      + ($sum | {version, installed, units_changed, apply} | with_entries(select(.value != null)))'
}

# ht_report - the last status document for the probe's check-in body, or null before the first run.
ht_report() { if [ -n "$HT_DOC" ]; then printf '%s' "$HT_DOC"; else printf 'null'; fi; }

# write_host_tools STATE MESSAGE [SUMMARY_JSON] - record the outcome. On a core we write the shared
# dir ourselves, atomically. On a probe our mount of the data folder is read-only, so the probe image
# writes it for us: once more as root, offline, with only that folder bound.
write_host_tools() {
  _sum="${3:-}"
  printf '%s' "$_sum" | jq -e 'type == "object"' >/dev/null 2>&1 || _sum='{}'
  HT_DOC=$(ht_doc "$1" "$2" "$_sum" 2>/dev/null) || HT_DOC=""
  [ -n "$HT_DOC" ] || return 0
  case "$HT_ROLE" in
    probe)
      [ -n "$HT_DIR" ] && [ -n "$HT_IMG" ] || return 0
      docker run --rm --network none --user 0:0 --read-only --cap-drop ALL \
        --cap-add DAC_OVERRIDE --cap-add FOWNER --cap-add CHOWN \
        --mount "type=bind,src=$HT_DIR,dst=/update" \
        --entrypoint sh "$HT_IMG" -c 'umask 022; printf "%s\n" "$1" > /update/host-tools.json.tmp && mv -f /update/host-tools.json.tmp /update/host-tools.json' _ "$HT_DOC" >/dev/null 2>&1 || true ;;
    *)
      printf '%s\n' "$HT_DOC" > "$HOST_TOOLS_FILE.tmp" 2>/dev/null && mv "$HOST_TOOLS_FILE.tmp" "$HOST_TOOLS_FILE" 2>/dev/null || true ;;
  esac
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

# sync_host_tools - one round: install the managed image's host tools when due.
sync_host_tools() {
  case "$HT_ROLE" in
    probe) _hname=$(resolve_proxy 2>/dev/null || true) ;;
    *)     _hname=$(resolve_core 2>/dev/null || true) ;;
  esac
  [ -z "$_hname" ] && return 0
  _himg=$(api GET "/containers/$_hname/json" 2>/dev/null | jq -r '.Image // empty' 2>/dev/null || true)
  [ -z "$_himg" ] && return 0
  _hnow=$(epoch)
  host_tools_due "$_himg" "$_hnow" || return 0
  HT_IMG="$_himg"; HT_AT="$_hnow"
  if [ "$HT_ROLE" = "probe" ]; then
    if [ ! -f "${PROBE_DIR:-/probe}/host-tools.json" ]; then
      # Nothing is written here: that file is the sign of a probe VM, and this host has none.
      HT_STATE=skipped; HT_DIR=""
      HT_DOC=$(ht_doc skipped "this host was not set up as a probe VM (no host tools from an image build): nothing to keep current here" '{}' 2>/dev/null) || HT_DOC=""
      return 0
    fi
    HT_DIR=$(host_probe_dir)
    _hep=python3; _hcmd=/host-tools/install-host-tools.py
  else
    if [ ! -f "${UPDATE_DIR:-/update}/os-status.json" ]; then
      HT_STATE=skipped
      write_host_tools skipped "this host was not set up as an Argus core (no host reporter): nothing to keep current here"
      return 0
    fi
    HT_DIR=$(host_update_dir)
    _hep=/argus; _hcmd=install-host-tools
  fi
  _hlabel=$(api GET "/images/$_himg/json" 2>/dev/null | jq -r '.Config.Labels["io.argus.host-tools"] // empty' 2>/dev/null || true)
  if [ -z "$_hlabel" ]; then
    HT_STATE=skipped
    write_host_tools skipped "this image doesn't carry its host tools yet; they come with the next update"
    return 0
  fi
  if [ -z "$HT_DIR" ]; then
    HT_STATE=failed
    _hvar=ARGUS_HOST_UPDATE_DIR; [ "$HT_ROLE" = "probe" ] && _hvar=ARGUS_HOST_PROBE_DIR
    HT_DOC=$(ht_doc failed "could not tell the host path of the state folder (set $_hvar on the sidecar)" '{}' 2>/dev/null) || HT_DOC=""
    [ "$HT_ROLE" = "probe" ] || write_host_tools failed "could not tell the host path of the state folder (set $_hvar on the sidecar)"
    log "installing the host tools failed: the host path of the state folder is unknown (set $_hvar)"
    return 0
  fi
  _hout=$(docker run --rm --network none --user 0:0 --read-only --cap-drop ALL \
            --cap-add DAC_OVERRIDE --cap-add FOWNER --cap-add CHOWN \
            --mount "type=bind,src=/usr/local/sbin,dst=/host/usr/local/sbin" \
            --mount "type=bind,src=/etc/systemd/system,dst=/host/etc/systemd/system" \
            --mount "type=bind,src=$HT_DIR,dst=/update" \
            --entrypoint "$_hep" "$_himg" "$_hcmd" --root /host --state-dir "$HT_DIR" --update-dir /update 2>&1) && _hrc=0 || _hrc=$?
  if [ "$_hrc" -eq 0 ]; then
    HT_STATE=ok
    _hsum=$(printf '%s\n' "$_hout" | tail -n 1)
    write_host_tools ok "" "$_hsum"
    _hn=$(printf '%s' "$_hsum" | jq -r '(.installed // []) | length' 2>/dev/null || echo 0)
    if [ "$_hn" != "0" ]; then log "installed $_hn host tool file(s); $(printf '%s' "$_hsum" | jq -r 'if .apply then "the host reloads systemd" else "no unit changed" end' 2>/dev/null)"; fi
  elif printf '%s' "$_hout" | grep -qi 'bind source path does not exist'; then
    HT_STATE=skipped
    write_host_tools skipped "this host has no /etc/systemd/system or /usr/local/sbin to install into (not a $HT_ROLE VM)"
  else
    HT_STATE=failed
    _hmsg=$(printf '%s' "$_hout" | sed 's/^argus install-host-tools: //; s/^install-host-tools: //' | tr '\n' ' ' | sed 's/ *$//' | cut -c1-200)
    write_host_tools failed "$_hmsg"
    log "installing the host tools failed: $_hmsg"
  fi
  return 0
}
