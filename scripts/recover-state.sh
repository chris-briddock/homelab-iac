#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# State recovery: recreates the postgres VM (tofu state backend) after the
# state was lost (postgres volume wiped by `podman system reset --force`).
#
# Procedure:
#   1. Switch tofu to a temporary local state backend
#   2. Import all existing libvirt resources (except postgres)
#   3. Destroy + recreate the postgres VM (fresh cloud-init boot)
#   4. Wait for postgres to come up + create the tofu_state DB/role
#   5. Switch tofu back to the pg backend
#
# Prerequisites:
#   - vhost proxy running (scripts/vhost-proxy.sh)
#   - TF_VAR_tf_encryption_passphrase set in env
#   - TF_VAR_gitea_runner_registration_token set in env
#   - The OLD PG_CONN_STR password is LOST — the new one will be
#     random_password.postgres.result (same as POSTGRES_PASSWORD).
#     Update PG_CONN_STR after this script completes.
#
# Usage:
#   scripts/recover-state.sh
#
# After completion, update PG_CONN_STR to use the new postgres password:
#   export PG_CONN_STR="postgres://tofu:<new-password>@192.168.70.11:5432/tofu_state?sslmode=disable"
# The <new-password> is random_password.postgres.result — retrieve it with:
#   tofu output postgres_password
# (add an output for it, or read it from the state: tofu state show random_password.postgres)
# ---------------------------------------------------------------------------
set -euo pipefail
cd "$(dirname "$0")/.."

export LIBVIRT_DEFAULT_URI="qemu:///system?socket=/tmp/vhost-libvirt.sock"

echo "================================================================"
echo "  STATE RECOVERY: recreating postgres VM + tofu state backend"
echo "================================================================"

# ---------------------------------------------------------------------------
# Step 1: Switch to local backend (pg backend is down — can't reach it).
# Temporarily comment out the backend "pg" block in versions.tf so tofu
# falls back to local state. We restore it at the end.
# ---------------------------------------------------------------------------
echo ""
echo "=== Step 1: Switch to local state backend ==="
cp versions.tf versions.tf.bak
sed -i '/backend "pg"/,/^[[:space:]]*}/ s/^/#/' versions.tf
# Remove the .terraform dir to clear cached backend metadata from the old
# pg backend — tofu init -reconfigure alone doesn't always clear it, and
# the stale .terraform/terraform.tfstate still references "pg", causing
# "Backend initialization required" errors on subsequent tofu commands.
rm -rf .terraform
tofu init -reconfigure
echo "  (versions.tf backed up to versions.tf.bak; pg backend commented out)"

# Cleanup function: restore versions.tf on exit
cleanup() {
  if [ -f versions.tf.bak ]; then
    mv versions.tf.bak versions.tf
    echo "  (versions.tf restored)"
  fi
}
trap cleanup EXIT

# ---------------------------------------------------------------------------
# Step 2: Import all existing libvirt resources EXCEPT postgres.
# (postgres will be recreated from scratch — its volume is gone.)
# ---------------------------------------------------------------------------
echo ""
echo "=== Step 2: Import existing libvirt resources (skip postgres) ==="

POOL="tofu-vms"
POOL_DIR="/var/lib/libvirt/images/tofu-vms"
POOL_UUID="$(virsh pool-uuid "${POOL}")"

imp() {
  if tofu state list 2>/dev/null | grep -qxF "$1"; then
    echo "skip (in state): $1"
    return 0
  fi
  echo "import: $1 <- $2"
  tofu import -input=false "$1" "$2" >/dev/null
}

# Shared resources
imp "libvirt_pool.vhost"        "${POOL_UUID}"
imp "libvirt_volume.base_vhost" "${POOL_DIR}/fedora-cloud-base.qcow2"

# All VMs EXCEPT postgres (postgres will be recreated)
SIMPLE_VMS=(
  "surrealdb|surrealdb-vm"
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

echo "=== Import complete. State list: ==="
tofu state list

# ---------------------------------------------------------------------------
# Step 3: Destroy the old postgres VM (domain + volumes) and recreate.
# The old postgres volume is gone (podman reset wiped it), so we just need
# to destroy the domain. Then apply will recreate everything fresh.
# ---------------------------------------------------------------------------
echo ""
echo "=== Step 3: Destroy old postgres domain ==="
# The domain is still registered in libvirt even though the disk is corrupted.
# Remove it from libvirt so tofu can recreate it cleanly.
virsh destroy postgres-vm 2>/dev/null || true
virsh undefine postgres-vm --nvram 2>/dev/null || true
# Also remove the old disk volume if it still exists
virsh vol-delete postgres-vm.qcow2 --pool tofu-vms 2>/dev/null || true
virsh vol-delete postgres-vm-cloudinit.iso --pool tofu-vms 2>/dev/null || true

# ---------------------------------------------------------------------------
# Step 4: Apply to recreate postgres (fresh cloud-init boot).
# Target only the postgres module to avoid touching other VMs.
# The sync provisioner is disabled for postgres (auto_sync = false) because
# this is a fresh boot — cloud-init runs automatically.
# Actually, auto_sync defaults to true. The sync will run AFTER the VM boots,
# which is fine — it's idempotent and the hash will match (fresh boot = fresh
# cloud-init). But we need the SSH key to work. Set auto_sync=false for this
# apply to avoid the sync racing with cloud-init.
# ---------------------------------------------------------------------------
echo ""
echo "=== Step 4: Apply to recreate postgres VM ==="
echo "    (targeting only module.postgres; fresh cloud-init boot)"
tofu plan -out /tmp/pg-recreate.plan -target=module.postgres
tofu apply /tmp/pg-recreate.plan

# ---------------------------------------------------------------------------
# Step 5: Wait for postgres to come up and create the tofu_state DB.
# The extra_runcmd in services.tf creates the tofu role + tofu_state DB
# automatically on first boot. Wait for it.
# ---------------------------------------------------------------------------
echo ""
echo "=== Step 5: Waiting for postgres + tofu_state DB ==="
echo "    (cloud-init extra_runcmd creates the tofu role + DB automatically)"
POSTGRES_IP="192.168.70.11"

# Get the postgres password from state (random_password.postgres.result)
PG_PASSWORD="$(tofu output -raw postgres_password 2>/dev/null || tofu state show random_password.postgres 2>/dev/null | grep 'result' | awk -F'=' '{print $2}' | tr -d ' "' || echo '')"

if [ -z "$PG_PASSWORD" ]; then
  echo "WARNING: Could not extract postgres password from state."
  echo "  The tofu_state DB password will be the same as POSTGRES_PASSWORD."
  echo "  Retrieve it with: tofu state show random_password.postgres"
fi

echo "Waiting for postgres to accept connections..."
tries=0
until pg_isready -h "$POSTGRES_IP" -p 5432 -U postgres >/dev/null 2>&1; do
  tries=$((tries + 1))
  if [ "$tries" -ge 60 ]; then
    echo "ERROR: postgres at $POSTGRES_IP not ready after 60 attempts" >&2
    echo "  Check: ssh -i ~/.ssh/fedora_deploy_ed25519 fedora@$POSTGRES_IP 'systemctl status postgres.service'" >&2
    exit 1
  fi
  echo "  waiting for postgres... (attempt $tries/60)"
  sleep 5
done
echo "postgres is up!"

# Wait a bit more for cloud-init to create the tofu role + DB
echo "Waiting for tofu_state DB to be created by cloud-init..."
tries=0
until PGPASSWORD="$PG_PASSWORD" psql -h "$POSTGRES_IP" -U tofu -d tofu_state -c 'SELECT 1' >/dev/null 2>&1; do
  tries=$((tries + 1))
  if [ "$tries" -ge 30 ]; then
    echo "WARNING: tofu_state DB not accessible after 30 attempts." >&2
    echo "  The cloud-init extra_runcmd may still be running." >&2
    echo "  Create it manually:" >&2
    echo "    PGPASSWORD='$PG_PASSWORD' psql -h $POSTGRES_IP -U postgres -c \"CREATE ROLE tofu LOGIN PASSWORD '$PG_PASSWORD'\"" >&2
    echo "    PGPASSWORD='$PG_PASSWORD' psql -h $POSTGRES_IP -U postgres -c 'CREATE DATABASE tofu_state OWNER tofu'" >&2
    exit 1
  fi
  echo "  waiting for tofu_state DB... (attempt $tries/30)"
  sleep 5
done
echo "tofu_state DB is ready!"

# ---------------------------------------------------------------------------
# Step 6: Switch back to the pg backend.
# ---------------------------------------------------------------------------
echo ""
echo "=== Step 6: Switch back to pg state backend ==="
echo "  Update PG_CONN_STR to use the new password:"
echo "  export PG_CONN_STR=\"postgres://tofu:${PG_PASSWORD}@${POSTGRES_IP}:5432/tofu_state?sslmode=disable\""
echo ""
echo "  Then run:"
echo "  tofu init -reconfigure"
echo ""
echo "  (this script cannot auto-set PG_CONN_STR because the pg backend"
echo "   reads it from the environment — set it manually, then run init)"

echo ""
echo "================================================================"
echo "  RECOVERY COMPLETE"
echo "================================================================"
echo ""
echo "  1. Set the new PG_CONN_STR (password shown above)"
echo "  2. Run: tofu init -reconfigure"
echo "  3. Run: tofu plan -out /tmp/full-fix.plan"
echo "  4. Run: tofu apply /tmp/full-fix.plan"
echo ""
echo "  The full apply will push the corrected sync script to all VMs"
echo "  and apply the DoH/ACME fixes (dns-lb :80/:443, dns1/dns2 SAN)."
