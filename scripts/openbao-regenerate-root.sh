#!/usr/bin/env bash
# scripts/openbao-regenerate-root.sh
#
# Robust one-shot OpenBao root regeneration using 3-of-5 recovery shares,
# executed entirely on openbao-vm (192.168.70.27). Never echoes shares.
# Prints only the final s.XXX... root token.
#
# Fix (this rewrite): the previous version silently failed because
#    ssh -t bash -s <<EOF   cannot allocate a TTY for bash-with-stdin-fed-script,
# AND `podman exec -i ... bao status -format=json` printed ">2MB" worth of
# diagnostic output we didn't tee off, so `set -e` aborted silently.
#
# New approach:
#   - All interactive prompts happen on the WORKSTATION.
#   - bao calls on .27 are issued as discrete, separately-invoked ssh commands.
#   - Every step prints a progress marker BEFORE and AFTER it returns,
#     so a failure is always attributed to a specific step.
#
# Use-case: no valid root token exists; run when `bao operator generate-root -init`
# returns 403 because you have no token to present to the API gate.
#
# Usage on workstation:
#   bash ~/Projects/infra/scripts/openbao-regenerate-root.sh
#
# Prerequisites:
#   - ssh access:  -i ~/.ssh/fedora_deploy_ed25519 fedora@192.168.70.27
#   - python3 available on BOTH the workstation and openbao-vm
#   - 5 recovery shares saved in your password manager (set during Phase 2-bis)

set -Eeuo pipefail

readonly VM_IP="192.168.70.27"
readonly SSH_OPTS=( -o BatchMode=no -o ConnectTimeout=8 -o LogLevel=ERROR \
                    -i ~/.ssh/fedora_deploy_ed25519 )
readonly BAO_EXEC_PREFIX=( sudo podman exec -e BAO_ADDR=http://127.0.0.1:8200 openbao )

abort() { echo; echo "== ABORT: $* ==" >&2; exit 1; }
note()  { printf '== %s ==\n' "$*"; }

# ---------------------------------------------------------------------------
# Phase 0 — connectivity + cluster state sanity
# ---------------------------------------------------------------------------
note "0. checking cluster reachability + seal status"

CLUSTER_STATE=$( ssh "${SSH_OPTS[@]}" "fedora@${VM_IP}" \
  "${BAO_EXEC_PREFIX[@]} bao status -format=json" \
) || abort "could not reach bao on ${VM_IP}"

SEALED=$( python3 -c 'import sys,json; print(json.loads(sys.stdin.read())["sealed"])' \
           <<<"$CLUSTER_STATE")
[[ "$SEALED" == "False" ]] || abort "server is sealed; can't regenerate root"

echo "   cluster reachable; unsealed ✓"

# ---------------------------------------------------------------------------
# Phase 1 — start the generate-root attempt (works without auth token, uses
# recovery keys; THIS is the operator-side endpoint)
# ---------------------------------------------------------------------------
note "1. starting generate-root attempt (-init)"

INIT_JSON=$( ssh "${SSH_OPTS[@]}" "fedora@${VM_IP}" \
  "${BAO_EXEC_PREFIX[@]} bao operator generate-root -init -format=json" \
) || abort "generate-root -init failed — you may already have an attempt in progress;\
cancel first: bao operator generate-root -cancel"

NONCE=$( python3 -c 'import sys,json; d=json.loads(sys.stdin.read()); print(d.get("nonce",""))' \
           <<<"$INIT_JSON")
OTP=$(   python3 -c 'import sys,json; d=json.loads(sys.stdin.read()); print(d.get("otp",""))' \
           <<<"$INIT_JSON")

[[ -n "$NONCE" && -n "$OTP" ]] || abort "init returned an empty nonce or otp\
(full JSON: $(head -c 200 <<<"$INIT_JSON"))"

echo "   attempt started"

# ---------------------------------------------------------------------------
# Phase 2 — feed shares one at a time (each call is a separate ssh command so
# the prompt can be on the WORKSTATION)
# ---------------------------------------------------------------------------
note "2. providing recovery shares (3 required)"

ENCODED=""
for idx in 1 2 3; do
  # prompt on the workstation, hidden
  read -rsp "  share #$idx (paste, Enter): " SHARE; echo
  [[ -n "$SHARE" ]] || abort "empty share"

  SHARE_OUT=$( ssh "${SSH_OPTS[@]}" "fedora@${VM_IP}" \
    "${BAO_EXEC_PREFIX[@]} bao operator generate-root -nonce=$NONCE -format=json -" \
    <<<"$SHARE" \
  ) || abort "share #$idx rejected by OpenBao"

  PROGRESS=$( python3 -c 'import sys,json; d=json.loads(sys.stdin.read()); print(d.get("progress",0))' \
                <<<"$SHARE_OUT")
  COMPLETE=$( python3 -c 'import sys,json; d=json.loads(sys.stdin.read()); print(d.get("complete",False))' \
                <<<"$SHARE_OUT")

  echo "   share #$idx accepted ($PROGRESS/3)"

  if [[ "$COMPLETE" == "True" ]]; then
    ENCODED=$( python3 -c 'import sys,json; d=json.loads(sys.stdin.read()); print(d.get("encoded_token",""))' \
                 <<<"$SHARE_OUT")
    break
  fi
  unset SHARE
done

[[ -n "$ENCODED" ]] || abort "did not reach threshold after 3 shares"

# ---------------------------------------------------------------------------
# Phase 3 — decode with OTP → root token
# ---------------------------------------------------------------------------
note "3. decoding with OTP"

ROOT_TOKEN=$( ssh "${SSH_OPTS[@]}" "fedora@${VM_IP}" \
  "${BAO_EXEC_PREFIX[@]} bao operator generate-root -decode=$ENCODED -otp=$OTP" \
  | awk '/^Root token:/ {print $3; exit}'
) || abort "decode failed"

[[ -n "$ROOT_TOKEN" ]] || abort "decode returned an empty token"

note "DONE — new root token"
echo
echo "  $ROOT_TOKEN"
echo
echo "Save to password manager immediately. Then mint a personal root via:"
echo "  bao login $ROOT_TOKEN"
echo "  bao token create -policy=root -display-name=root-personal-$(date +%F) -ttl=0"
echo "  bao token revoke $ROOT_TOKEN"
