#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# State REBUILD (rotation): rebuild the OpenTofu remote state from scratch,
# KEEPING the postgres VM intact. Replaces the current pg-backend state with
# a fresh, encrypted state under a NEW passphrase, using a SEPARATE dedicated
# password for the `tofu` role (no longer shared with the postgres superuser).
#
# Why this exists:
#   - OpenTofu's state-encryption does NOT support two-key rotation via a
#     `fallback` block (tofu 1.12.4 treats any fallback as an active migration
#     and stops reading with the primary key -> "no decryption key available").
#     The only reliable way to rotate the passphrase is: pull everything into
#     a fresh LOCAL state (new passphrase), then migrate it back to pg.
#   - We also want the `tofu` role to have its own password (separate from
#     the postgres superuser), and to DROP + recreate the tofu_state DB so it
#     contains only the migrated fresh state.
#
# What this script does:
#   1. Switch tofu to a temporary LOCAL backend (new passphrase)
#   2. ALTER ROLE tofu -> dedicated tofu_state_password (from OpenBao)
#   3. DROP DATABASE tofu_state + CREATE DATABASE tofu_state (owner tofu)
#      (done while on the local backend so nothing holds a connection to it)
#   4. Import ALL existing libvirt resources (pools, volumes, domains) for
#      EVERY VM — including postgres and the openbao VMs — volumes persist
#   5. tofu apply -> recreates all NON-libvirt resources (config_sync, data
#      sources, vault resources, PKI files) against the SAME live VMs
#   6. Switch back to the pg backend with the NEW PG_CONN_STR (tofu role +
#      tofu_state_password) -> migrates the fresh local state into the fresh
#      tofu_state DB
#
# Prerequisites (exported in env before running):
#   TF_VAR_tf_encryption_passphrase   = NEW passphrase (this script can
#                                       generate one if you leave it unset —
#                                       see GENERATE_PASS=1)
#   TF_VAR_gitea_runner_registration_token
#   TF_VAR_openbao_root_token         = main cluster root token (s.OZTQ...)
#   POPG_CONN (optional)              = superuser connstring for postgres
#                                       default: postgres://postgres:<pw>@…
#   vhost proxy running: scripts/vhost-proxy.sh
#
# Secrets are pulled from OpenBao (main root token) — never on disk.
#   postgres superuser pw:  secret/data/platform/services/postgres_password
#   tofu role pw (new):     secret/data/platform/services/tofu_state_password
#
# Usage:
#   scripts/rebuild-state.sh
#
# After completion:
#   - SAVE the NEW passphrase + tofu role password in your password manager.
#   - PG_CONN_STR is now:
#       postgres://tofu:<tofu_state_password>@192.168.70.11:5432/tofu_state?sslmode=disable
# ---------------------------------------------------------------------------
set -euo pipefail
cd "$(dirname "$0")/.."

export LIBVIRT_DEFAULT_URI="qemu:///system?socket=/tmp/vhost-libvirt.sock"

POOL="tofu-vms"
POOL_DIR="/var/lib/libvirt/images/tofu-vms"
POSTGRES_IP="192.168.70.11"
# Talk to the openbao cluster DIRECTLY (bypass the caddy on openbao-vm): the
# apply restarts the caddy container mid-apply, which 502s every vault call.
POSTGRES_IP="192.168.70.11"
OPENBAO_IP="192.168.70.27"
OPENBAO_ADDR="http://${OPENBAO_IP}:8200"
ROOT_CA="$(pwd)/pki/root-ca.crt"

# Transit recovery (shamir) keys — needed to unseal transit .28 after the apply
# restarts it (shamir seals every restart, which then crashes main auto-unseal).
# Accept comma- or space-separated via TRANSIT_KEYS env.
TRANSIT_KEYS="${TRANSIT_KEYS:-}"

echo "================================================================"
echo "  STATE REBUILD: keep postgres VM; rotate passphrase + tofu pw"
echo "================================================================"

# ---------------------------------------------------------------------------
# Env checks
# ---------------------------------------------------------------------------
# gitea_runner_registration_token is only consumed by module.gitea_runner at
# runner registration; we are NOT re-registering runners (all VMs kept), so a
# non-empty placeholder satisfies the variable for this apply.
: "${TF_VAR_gitea_runner_registration_token:=REBUILD-NOT-REGISTERING}"
export TF_VAR_gitea_runner_registration_token
: "${TF_VAR_openbao_root_token:?set TF_VAR_openbao_root_token (main root s.OZTQ...)}"
ROOT_TOKEN="$TF_VAR_openbao_root_token"

# Generate (or accept) the NEW passphrase. Prefer PASS=value so the passphrase
# is captured BEFORE any step runs. If GENERATE_PASS=1 (default) and none was
# supplied, one is generated here... but it is wiped from tofu's reach on any
# early failure, so this script re-generates per run only as a last resort —
# STRONGLY prefer passing PASS explicitly.
if [ -z "${TF_VAR_tf_encryption_passphrase:-}" ]; then
  if [ -n "${PASS:-}" ]; then
    TF_VAR_tf_encryption_passphrase="$PASS"
    export TF_VAR_tf_encryption_passphrase
    echo "  Using caller-supplied PASS for TF_VAR_tf_encryption_passphrase."
  elif [ "${GENERATE_PASS:-1}" = "1" ]; then
    TF_VAR_tf_encryption_passphrase="$(openssl rand -base64 36 | tr -d '\n')"
    export TF_VAR_tf_encryption_passphrase
    echo "  Generated NEW TF_VAR_tf_encryption_passphrase."
    echo "  NEW_PASS=${TF_VAR_tf_encryption_passphrase}"
  else
    echo "ERROR: set PASS=<new passphrase> or TF_VAR_tf_encryption_passphrase" >&2
    exit 1
  fi
fi
NEW_PASS="$TF_VAR_tf_encryption_passphrase"

# Persist the NEW passphrase to a root-readable temp file IMMEDIATELY so an
# early failure (set -e) never loses it (the tofu local state is unreadable
# without it). Shredded by the caller after the final migrate succeeds.
PASS_FILE="${PASS_FILE:-/tmp/rebuild_new_pass.txt}"
umask 077
printf '%s' "$NEW_PASS" > "$PASS_FILE"
echo "  NEW passphrase captured to $PASS_FILE (mode 600) — save + shred after success."

if ! command -v curl >/dev/null || ! command -v jq >/dev/null || ! command -v psql >/dev/null; then
  echo "ERROR: need curl, jq, psql on PATH" >&2
  exit 1
fi

# Helper: direct (no TLS) calls to openbao. Retries: openbao may be mid-restart.
bao_get() { # bao_get <path> <field>
  local out i
  for i in $(seq 1 12); do
    if out="$(curl -sf -H "X-Vault-Token: $ROOT_TOKEN" \
              "$OPENBAO_ADDR/v1/secret/data/$1")" && [ -n "$out" ]; then
      printf '%s' "$out" | jq -r ".data.data.$2"
      return 0
    fi
    sleep 4
  done
  return 1
}

# restore_openbao: unseal TRANSIT (.28) with TRANSIT_KEYS, then restart + wait
# for MAIN (.27) to auto-unseal. No-ops when already healthy.
restore_openbao() {
  echo "  Restoring openbao (unseal transit -> restart main)..."
  if [ -n "$TRANSIT_KEYS" ]; then
    # split comma/space-separated keys
    read -r -a _keys <<<"$(printf '%s' "$TRANSIT_KEYS" | tr ',' ' ')"
    for k in "${_keys[@]}"; do
      ssh -i ~/.ssh/fedora_deploy_ed25519 -o StrictHostKeyChecking=no "fedora@${OPENBAO_TRANSIT_IP:-192.168.70.28}" \
        "sudo podman exec -e BAO_ADDR=http://127.0.0.1:8200 openbao-transit bao operator unseal '$k'" >/dev/null 2>&1 || true
    done
  fi
  ssh -i ~/.ssh/fedora_deploy_ed25519 -o StrictHostKeyChecking=no "fedora@${OPENBAO_IP}" \
    "sudo podman restart openbao >/dev/null 2>&1" || true
  sleep 6
}

echo "  Waiting for OpenBao to be reachable..."
ready=0
for i in $(seq 1 24); do
  code=$(curl -s -o /dev/null -w '%{http_code}' "$OPENBAO_ADDR/v1/sys/health" || true)
  if [ "$code" = "200" ]; then ready=1; break; fi
  if [ "$i" = "8" ] && [ -n "$TRANSIT_KEYS" ]; then restore_openbao; fi
  echo "    openbao health http=$code (attempt $i/24)"
  sleep 5
done
[ "$ready" = "1" ] || { echo "ERROR: OpenBao not healthy at $OPENBAO_ADDR (transit sealed? set TRANSIT_KEYS)" >&2; exit 1; }

echo "  Fetching postgres superuser + tofu role passwords from OpenBao..."
PG_SUPER_PW="$(bao_get platform/services/postgres_password value)"
TOFU_PW="$(bao_get platform/services/tofu_state_password value)"
if [ -z "$PG_SUPER_PW" ] || [ "$PG_SUPER_PW" = "null" ] || [ -z "$TOFU_PW" ] || [ "$TOFU_PW" = "null" ]; then
  echo "ERROR: could not read postgres_password / tofu_state_password from OpenBao" >&2
  exit 1
fi
echo "  OK (tofu role pw sha12=$(printf '%s' "$TOFU_PW" | sha256sum | cut -c1-12))"

# Connstring to the DB that the SQL runs against (a built-in DB, not tofu_state).
PG_ADMIN="postgres://postgres:${PG_SUPER_PW}@${POSTGRES_IP}:5432/postgres?sslmode=disable"

# ---------------------------------------------------------------------------
# Step 1: switch to a LOCAL state backend using the NEW passphrase.
# versions.tf is backed up and restored on exit via trap.
# ---------------------------------------------------------------------------
echo ""
echo "=== Step 1: switch to LOCAL backend (NEW passphrase) ==="
cp versions.tf versions.tf.bak
sed -i '/backend "pg"/,/^[[:space:]]*}/ s/^/#/' versions.tf
rm -rf .terraform
# Discard any orphaned local state from a prior failed rebuild — it would be
# encrypted with a different (lost) passphrase and tofu init would abort on
# "message authentication failed". We rebuild local state from scratch.
rm -f terraform.tfstate terraform.tfstate.backup

cleanup() {
  if [ -f versions.tf.bak ]; then
    mv versions.tf.bak versions.tf
    echo "  (versions.tf restored to pg backend)"
  fi
}
trap cleanup EXIT

tofu init -reconfigure
echo "  Local backend ready; state will live at terraform.tfstate (NEW passphrase)."

# ---------------------------------------------------------------------------
# Step 2: point the `tofu` role at its dedicated password.
# Step 3: DROP + recreate tofu_state (owner tofu). Nothing is connected to
#         tofu_state right now because tofu is on the LOCAL backend.
# ---------------------------------------------------------------------------
echo ""
echo "=== Step 2: ALTER ROLE tofu -> dedicated tofu_state_password ==="
psql "$PG_ADMIN" -v ON_ERROR_STOP=1 \
  -c "ALTER ROLE tofu WITH LOGIN PASSWORD '${TOFU_PW}'"
echo "  tofu role password updated."

echo ""
echo "=== Step 3: DROP + recreate tofu_state DB ==="
# Terminate any lingering connections to tofu_state just in case.
psql "$PG_ADMIN" -v ON_ERROR_STOP=1 \
  -c "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname='tofu_state' AND pid <> pg_backend_pid()" \
  >/dev/null || true
psql "$PG_ADMIN" -v ON_ERROR_STOP=1 -c "DROP DATABASE IF EXISTS tofu_state"
psql "$PG_ADMIN" -v ON_ERROR_STOP=1 -c "CREATE DATABASE tofu_state OWNER tofu"
psql "$PG_ADMIN" -v ON_ERROR_STOP=1 -c "GRANT ALL PRIVILEGES ON DATABASE tofu_state TO tofu"
echo "  tofu_state recreated (owner tofu)."

# ---------------------------------------------------------------------------
# Step 4: import ALL existing libvirt resources (every VM — KEEP postgres).
# ---------------------------------------------------------------------------------
echo ""
echo "=== Step 4: import existing libvirt resources (ALL VMs) ==="
POOL_UUID="$(virsh pool-uuid "${POOL}")"

imp() {
  if tofu state list 2>/dev/null | grep -qxF "$1"; then
    echo "skip (in state): $1"
    return 0
  fi
  echo "import: $1 <- $2"
  tofu import -input=false "$1" "$2" >/dev/null
}

# Drop any stale libvirt entries if re-running.
for addr in $(tofu state list 2>/dev/null | grep -E '(^|\.)libvirt_'); do
  echo "rm: ${addr}"
  tofu state rm "${addr}" >/dev/null
done

imp "libvirt_pool.vhost"        "${POOL_UUID}"
imp "libvirt_volume.base_vhost" "${POOL_DIR}/fedora-cloud-base.qcow2"

# vault_* resources already EXIST on the OpenBao server (created on the prior
# Day-2 apply, which lived in the now-dropped state). Import them so apply
# adopts them in place instead of failing on "already in use at userpass/".
imp "vault_auth_backend.userpass"     "userpass"
imp "vault_policy.operator"           "operator"
imp "vault_generic_endpoint.admin_user" "auth/userpass/users/${TF_VAR_openbao_admin_username:-chris}"

# Simple module VMs — INCLUDES postgres, plus the openbao VMs.
SIMPLE_VMS=(
  "surrealdb|surrealdb-vm"
  "postgres|postgres-vm"
  "penpot|penpot-vm"
  "monitoring|monitoring-vm"
  "aspire|aspire-vm"
  "ca|ca-vm"
  "registry|registry-vm"
  "gitea|gitea-vm"
  "verdaccio|verdaccio-vm"
  "nfs|nfs-vm"
  "redis|redis-vm"
  "qvault|qvault-vm"
  "dns_lb|dns-lb-vm"
  "openbao|openbao-vm"
  "openbao_transit|openbao-transit-vm"
)

for row in "${SIMPLE_VMS[@]}"; do
  IFS='|' read -r key dom <<<"$row"
  imp "module.${key}.libvirt_volume.disk"       "${POOL_DIR}/${dom}.qcow2"
  if virsh vol-path "${dom}-cloudinit.iso" --pool "${POOL}" >/dev/null 2>&1; then
    imp "module.${key}.libvirt_volume.cloudinit"  "${POOL_DIR}/${dom}-cloudinit.iso"
  fi
  uuid="$(virsh domuuid "${dom}")"
  imp "module.${key}.libvirt_domain.vm"          "${uuid}"
done

# dns uses for_each
for k in dns1 dns2; do
  dom="${k}-vm"
  imp "module.dns[\"${k}\"].libvirt_volume.disk"       "${POOL_DIR}/${dom}.qcow2"
  if virsh vol-path "${dom}-cloudinit.iso" --pool "${POOL}" >/dev/null 2>&1; then
    imp "module.dns[\"${k}\"].libvirt_volume.cloudinit"  "${POOL_DIR}/${dom}-cloudinit.iso"
  fi
  uuid="$(virsh domuuid "${dom}")"
  imp "module.dns[\"${k}\"].libvirt_domain.vm"          "${uuid}"
done

# gitea_runner uses for_each
for k in gitea-runner-1 gitea-runner-2; do
  dom="${k}-vm"
  imp "module.gitea_runner[\"${k}\"].libvirt_volume.disk"       "${POOL_DIR}/${dom}.qcow2"
  if virsh vol-path "${dom}-cloudinit.iso" --pool "${POOL}" >/dev/null 2>&1; then
    imp "module.gitea_runner[\"${k}\"].libvirt_volume.cloudinit"  "${POOL_DIR}/${dom}-cloudinit.iso"
  fi
  uuid="$(virsh domuuid "${dom}")"
  imp "module.gitea_runner[\"${k}\"].libvirt_domain.vm"          "${uuid}"
done

echo "=== Import complete ==="

# ---------------------------------------------------------------------------
# Step 5: apply to recreate the NON-libvirt resources against the live VMs
# (config_sync, data sources, vault resources, PKI). Local state is encrypted
# with the NEW passphrase.
# ---------------------------------------------------------------------------
echo ""
echo "=== Step 5: tofu apply (recreate non-libvirt resources, NEW passphrase) ==="
# Force the vault provider to the DIRECT openbao endpoint for this apply — the
# caddy on openbao-vm restarts mid-apply and would 502 every vault API call.
export VAULT_ADDR="$OPENBAO_ADDR"
tofu plan -out /tmp/rebuild.plan
tofu apply /tmp/rebuild.plan
unset VAULT_ADDR

# The apply likely restarted the caddy (harmless) but may have also sealed
# transit (.28) if its quadlet changed, which crashes main. Recover now.
restore_openbao
echo "  Confirming openbao healthy before migration..."
ok=0
for i in $(seq 1 24); do
  code=$(curl -s -o /dev/null -w '%{http_code}' "$OPENBAO_ADDR/v1/sys/health" || true)
  if [ "$code" = "200" ]; then ok=1; break; fi
  echo "    openbao health http=$code (attempt $i/24)"
  sleep 5
done
[ "$ok" = "1" ] || { echo "ERROR: openbao not healthy after apply; passphrase saved at $PASS_FILE" >&2; exit 1; }

# ---------------------------------------------------------------------------
# Step 6: switch back to pg + migrate the fresh local state into the fresh
# tofu_state DB. New PG_CONN_STR = tofu role + tofu_state_password.
# ---------------------------------------------------------------------------
echo ""
echo "=== Step 6: migrate local state -> pg backend (tofu role + dedicated pw) ==="
NEW_PG_CONN="postgres://tofu:${TOFU_PW}@${POSTGRES_IP}:5432/tofu_state?sslmode=disable"

# Restore pg backend in versions.tf (trap restores the .bak, this is explicit).
mv versions.tf.bak versions.tf

tofu init -migrate-state -force-copy -input=false \
  -backend-config="conn_str=${NEW_PG_CONN}"

echo "  State migrated local -> pg (tofu_state). Re-initialising complete."
echo "  Verifying steady-state (expect: No changes)..."
tofu plan -detailed-exitcode >/tmp/rebuild-steady.plan 2>&1 && rc=$? || rc=$?
if [ "$rc" = "0" ]; then
  echo "  Steady-state clean."
elif [ "$rc" = "2" ]; then
  echo "  NOTE: pending diffs after migration — review: tofu plan"
else
  echo "  WARNING: plan errored after migration (rc=$rc); see /tmp/rebuild-steady.plan"
fi

echo ""
echo "================================================================"
echo "  REBUILD COMPLETE"
echo "================================================================"
echo ""
echo "  SAVE THESE in your password manager NOW:"
echo "    NEW TF_VAR_tf_encryption_passphrase = ${NEW_PASS}"
echo "    tofu role password (tofu_state_password) sha12 = $(printf '%s' "$TOFU_PW" | sha256sum | cut -c1-12)"
echo ""
echo "  New PG_CONN_STR:"
echo "    export PG_CONN_STR=\"${NEW_PG_CONN}\""
echo ""
