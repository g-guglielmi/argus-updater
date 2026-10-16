#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 g-guglielmi
#
# Regression test for lib/recreate.sh's pull_verified: after the pull, the image must carry the
# digest the core handed out (when one was) AND a Sigstore signature from the workflow allowed to
# have built it. Pure: docker, the Engine API and cosign are faked (a cosign stub records its
# arguments and exits as told), so no daemon, no network and no real cosign are needed; only jq.
set -u
DIR=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck source=/dev/null
. "$DIR/lib/recreate.sh"   # defines sig_identity / verify_signature / pull_verified

command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not installed"; exit 0; }

fail=0
ok()   { echo "  ok   $1"; }
bad()  { echo "  FAIL $1"; fail=1; }

# The hooks recreate.sh expects from its caller, and the fakes.
log() { :; }
docker() { return 0; }   # the pull always "succeeds"
DIG="sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
OTHER="sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
api() { printf '%s' '{"RepoDigests":["ghcr.io/acme/argus@'"$DIG"'"]}'; }

FAKE=$(mktemp -d)
ARGS="$FAKE/cosign.args"
cat > "$FAKE/cosign" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" > "${FAKE_COSIGN_ARGS:?}"
[ "${FAKE_COSIGN_RC:-0}" = "0" ] || { echo "Error: no matching signatures" >&2; exit "$FAKE_COSIGN_RC"; }
echo '[{"critical":{}}]'
EOF
chmod +x "$FAKE/cosign"
PATH="$FAKE:$PATH"
export FAKE_COSIGN_ARGS="$ARGS"
unset ARGUS_VERIFY_SIGNATURES ARGUS_SIGNING_IDENTITY

echo "sig_identity: each of our images maps to the one workflow that may build it"
[ "$(sig_identity ghcr.io/acme/argus)" = '^https://github.com/acme/argus-core/.github/workflows/build.yml@' ] && ok "argus -> argus-core build.yml" || bad "argus identity: $(sig_identity ghcr.io/acme/argus)"
[ "$(sig_identity ghcr.io/acme/argus-probe)" = '^https://github.com/acme/argus-probe/.github/workflows/probe-image.yml@' ] && ok "argus-probe -> probe-image.yml" || bad "probe identity"
[ "$(sig_identity ghcr.io/acme/argus-updater)" = '^https://github.com/acme/argus-updater/.github/workflows/updater-image.yml@' ] && ok "argus-updater -> updater-image.yml" || bad "updater identity"
sig_identity ghcr.io/acme/something-else >/dev/null && bad "an unknown name got an identity" || ok "an unknown image name has no signer"
sig_identity argus >/dev/null && bad "a bare name got an identity" || ok "a bare name (no registry, no owner) has no signer"
ARGUS_SIGNING_IDENTITY='^https://github.com/fork/x@' ; [ "$(sig_identity ghcr.io/acme/argus)" = '^https://github.com/fork/x@' ] && ok "ARGUS_SIGNING_IDENTITY overrides" || bad "override"
unset ARGUS_SIGNING_IDENTITY

echo "pull_verified: handed-out digest matches and the signature verifies -> ok, cosign saw the digest"
rm -f "$ARGS"; export FAKE_COSIGN_RC=0
pull_verified ghcr.io/acme/argus:latest "$DIG" && ok "accepted" || bad "refused: $PULL_ERR"
grep -q -- "--certificate-oidc-issuer https://token.actions.githubusercontent.com" "$ARGS" 2>/dev/null && ok "issuer pinned" || bad "issuer not passed: $(cat "$ARGS" 2>/dev/null)"
grep -q -- "--certificate-identity-regexp ^https://github.com/acme/argus-core/.github/workflows/build.yml@" "$ARGS" 2>/dev/null && ok "identity is the core's workflow" || bad "identity: $(cat "$ARGS" 2>/dev/null)"
grep -q -- "ghcr.io/acme/argus@$DIG" "$ARGS" 2>/dev/null && ok "verified by digest, not by tag" || bad "ref: $(cat "$ARGS" 2>/dev/null)"

echo "pull_verified: a good digest but no valid signature -> refused, with the reason"
rm -f "$ARGS"; export FAKE_COSIGN_RC=10
pull_verified ghcr.io/acme/argus:latest "$DIG" && bad "accepted an unsigned image" || ok "refused"
case "$PULL_ERR" in *"not signed by its build"*) ok "reason names the signature" ;; *) bad "reason: $PULL_ERR" ;; esac

echo "pull_verified: a digest other than the one handed out -> refused before cosign runs"
rm -f "$ARGS"; export FAKE_COSIGN_RC=0
pull_verified ghcr.io/acme/argus:latest "$OTHER" && bad "accepted a swapped image" || ok "refused"
[ ! -f "$ARGS" ] && ok "cosign was not consulted" || bad "cosign ran for a wrong digest"

echo "pull_verified: no digest handed out -> the pulled one is taken and its signature checked"
rm -f "$ARGS"; export FAKE_COSIGN_RC=0
pull_verified ghcr.io/acme/argus:latest && ok "accepted" || bad "refused: $PULL_ERR"
grep -q -- "ghcr.io/acme/argus@$DIG" "$ARGS" 2>/dev/null && ok "the pulled digest was verified" || bad "ref: $(cat "$ARGS" 2>/dev/null)"

echo "pull_verified: an image none of our builds sign -> refused even with a good digest"
rm -f "$ARGS"; export FAKE_COSIGN_RC=0
api() { printf '%s' '{"RepoDigests":["ghcr.io/acme/other@'"$DIG"'"]}'; }
pull_verified ghcr.io/acme/other:latest "$DIG" && bad "accepted an image with no known signer" || ok "refused"
case "$PULL_ERR" in *"no build is known to sign"*) ok "reason says so" ;; *) bad "reason: $PULL_ERR" ;; esac
api() { printf '%s' '{"RepoDigests":["ghcr.io/acme/argus@'"$DIG"'"]}'; }

echo "ARGUS_VERIFY_SIGNATURES=0: the digest check alone, cosign never runs"
rm -f "$ARGS"; export FAKE_COSIGN_RC=10 ARGUS_VERIFY_SIGNATURES=0
pull_verified ghcr.io/acme/argus:latest "$DIG" && ok "accepted on the digest" || bad "refused: $PULL_ERR"
[ ! -f "$ARGS" ] && ok "cosign not consulted" || bad "cosign ran with verification off"
pull_verified ghcr.io/acme/argus:latest "$OTHER" && bad "a wrong digest passed with verification off" || ok "a wrong digest is still refused"
unset ARGUS_VERIFY_SIGNATURES

rm -rf "$FAKE"
echo "-----"
if [ "$fail" -eq 0 ]; then echo "PASS"; exit 0; else echo "FAIL"; exit 1; fi
