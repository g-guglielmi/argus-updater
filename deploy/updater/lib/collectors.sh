# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 g-guglielmi

# shellcheck shell=sh
# argus-updater - the core host's collectors (core mode).
#
# The core's Zabbix server is a host package, not a container: the collectors (external checks) it
# runs for the hosts it monitors live in the host's ExternalScripts folder, which no container update
# reaches. The Argus image carries them (/collectors, labelled io.argus.collectors) and copies them
# with `/argus install-collectors`. We hold the socket, so we run that very image once - as root, with
# no network and only that folder bound in - and write the outcome to collectors.json in the shared
# dir, where the core's Settings page reads it. A user never copies a collector by hand.
#
# When: the core's image changed since the last run (an update, a redeploy), a day after a success
# (puts back a deleted or edited collector), ten minutes after a failure. An image without the label
# (an Argus from before this) or a host without the folder (its Zabbix server runs elsewhere) is
# "skipped" until the image changes.
#
# Needs from the caller: api, resolve_core, now, log; UPDATE_DIR.

COLLECTORS_DIR="${ARGUS_COLLECTORS_DIR:-/usr/lib/zabbix/externalscripts}"
COLLECTORS_FILE="${UPDATE_DIR:-/update}/collectors.json"
COLL_IMG=""     # the core image id the last run was for
COLL_STATE=""   # ok | failed | skipped
COLL_AT=0       # when it ran (epoch seconds)

epoch() { date +%s; }

# write_collectors STATE MESSAGE [SUMMARY_JSON] - atomic, so the core never reads half a file.
write_collectors() {
  _sum="${3:-}"
  printf '%s' "$_sum" | jq -e 'type == "object"' >/dev/null 2>&1 || _sum='{}'
  jq -nc --arg s "$1" --arg m "$2" --arg at "$(now)" --arg img "$COLL_IMG" --arg dir "$COLLECTORS_DIR" --argjson sum "$_sum" \
     '{state:$s, at:$at, image:$img, dir:$dir} + (if $m == "" then {} else {message:$m} end)
      + ($sum | {version, installed} | with_entries(select(.value != null)))' \
     > "$COLLECTORS_FILE.tmp" 2>/dev/null && mv "$COLLECTORS_FILE.tmp" "$COLLECTORS_FILE" 2>/dev/null || true
}

# collectors_due IMAGE_ID NOW - whether to (re)install now.
collectors_due() {
  [ "$1" != "$COLL_IMG" ] && return 0
  case "$COLL_STATE" in
    ok)     [ $(($2 - COLL_AT)) -ge 86400 ] ;;
    failed) [ $(($2 - COLL_AT)) -ge 600 ] ;;
    *)      return 1 ;;   # skipped: nothing changes until the image does
  esac
}

# sync_collectors - one round: install the running core image's collectors when due.
sync_collectors() {
  _cname=$(resolve_core 2>/dev/null || true)
  [ -z "$_cname" ] && return 0
  _cimg=$(api GET "/containers/$_cname/json" 2>/dev/null | jq -r '.Image // empty' 2>/dev/null || true)
  [ -z "$_cimg" ] && return 0
  _cnow=$(epoch)
  collectors_due "$_cimg" "$_cnow" || return 0
  COLL_IMG="$_cimg"; COLL_AT="$_cnow"
  _clabel=$(api GET "/images/$_cimg/json" 2>/dev/null | jq -r '.Config.Labels["io.argus.collectors"] // empty' 2>/dev/null || true)
  if [ -z "$_clabel" ]; then
    COLL_STATE=skipped
    write_collectors skipped "this Argus version doesn't carry its collectors yet; they come with the next update"
    return 0
  fi
  _cout=$(docker run --rm --network none --user 0:0 --read-only --cap-drop ALL \
            --cap-add DAC_OVERRIDE --cap-add FOWNER \
            --mount "type=bind,src=$COLLECTORS_DIR,dst=/dst" \
            --entrypoint /argus "$_cimg" install-collectors /dst 2>&1) && _crc=0 || _crc=$?
  if [ "$_crc" -eq 0 ]; then
    COLL_STATE=ok
    _csum=$(printf '%s\n' "$_cout" | tail -n 1)
    write_collectors ok "" "$_csum"
    _cn=$(printf '%s' "$_csum" | jq -r '(.installed // []) | length' 2>/dev/null || echo 0)
    if [ "$_cn" != "0" ]; then log "installed $_cn collector(s) in $COLLECTORS_DIR"; fi
  elif printf '%s' "$_cout" | grep -qi 'bind source path does not exist'; then
    COLL_STATE=skipped
    write_collectors skipped "this host has no Zabbix external scripts folder at $COLLECTORS_DIR (its Zabbix server runs elsewhere)"
  else
    COLL_STATE=failed
    _cmsg=$(printf '%s' "$_cout" | sed 's/^argus install-collectors: //' | tr '\n' ' ' | sed 's/ *$//' | cut -c1-200)
    write_collectors failed "$_cmsg"
    log "installing the collectors failed: $_cmsg"
  fi
  return 0
}
