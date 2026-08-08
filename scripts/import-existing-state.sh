#!/usr/bin/env bash
# State-recovery import for dmacvicar/libvirt 0.9.x.
#
# Brings the existing libvirt resources (pools, volumes, domains) for the
# *already-provisioned* VMs back into OpenTofu state after the tfstate was
# lost and the provider was upgraded from 0.8.x to 0.9.x (full breaking
# rewrite — the old 0.8.x state entries are schema-incompatible and must
# be removed before re-importing with 0.9.x IDs).
#
# Net-new resources (gitea, verdaccio, their random_passwords, the PKI, and
# the local-default-provider pool/base) are deliberately NOT imported here —
# they are created by the subsequent `tofu apply`.
#
# Import ID formats for dmacvicar/libvirt 0.9.x (verified from source):
#   libvirt_pool            -> pool UUID          (Read: LookupPoolByUUID)
#   libvirt_volume          -> volume key = full on-disk path (Read: StorageVolLookupByKey)
#   libvirt_domain          -> domain UUID       (ImportState: path.Root("uuid"))
#   libvirt_cloudinit_disk  -> NOT importable (no ImportState method; the
#                              resource only generates a local temp ISO file
#                              and is regenerated on every plan/apply)
#
# The NEW libvirt_volume.cloudinit (uploads the cloudinit ISO into the pool)
# IS imported by path — it's a regular libvirt volume.
#
# Run with the vhost proxy up (scripts/vhost-proxy.sh).
#
# Usage: scripts/import-existing-state.sh
set -euo pipefail
cd "$(dirname "$0")/.."

export LIBVIRT_DEFAULT_URI="qemu:///system?socket=/tmp/vhost-libvirt.sock"
POOL="tofu-vms"
POOL_DIR="/var/lib/libvirt/images/tofu-vms"
POOL_UUID="$(virsh pool-uuid "${POOL}")"

# tofu import <ADDR> <ID>; tolerate already-in-state entries.
imp() {
  if tofu state list 2>/dev/null | grep -qxF "$1"; then
    echo "skip (in state): $1"
    return 0
  fi
  echo "import: $1 <- $2"
  tofu import -input=false "$1" "$2" >/dev/null
}

# ---------------------------------------------------------------------------
# Step 1: remove stale 0.8.x state entries (schema-incompatible with 0.9.x).
# ---------------------------------------------------------------------------
# The 0.8.x cloudinit_disk has a "pool" attribute that 0.9.x doesn't know
# about, causing "unsupported attribute" errors on any state operation.
# Remove ALL libvirt resources from state; random_password/tls entries
# (non-libvirt providers) are left intact.
echo "=== removing stale 0.8.x libvirt state entries ==="
for addr in $(tofu state list 2>/dev/null | grep -E '(^|\.)libvirt_'); do
  echo "rm: ${addr}"
  tofu state rm "${addr}" >/dev/null
done

# ---------------------------------------------------------------------------
# Step 2: import vhost provider shared resources (pool + base image).
# ---------------------------------------------------------------------------
echo "=== importing vhost shared resources ==="
imp "libvirt_pool.vhost"        "${POOL_UUID}"
imp "libvirt_volume.base_vhost" "${POOL_DIR}/fedora-cloud-base.qcow2"

# ---------------------------------------------------------------------------
# Step 3: per-VM resources on the vhost provider.
# ---------------------------------------------------------------------------
# (module-key, domain-name). Each VM has:
#   - libvirt_volume.disk       (root qcow2, imported by path)
#   - libvirt_volume.cloudinit   (cloudinit ISO, imported by path — NEW in 0.9.x)
#   - libvirt_domain.vm          (domain, imported by UUID)
#
# libvirt_cloudinit_disk.init is NOT imported — it has no ImportState in 0.9.x.
# It will be regenerated on the next plan (just creates a temp ISO; the
# libvirt_volume.cloudinit already holds the uploaded ISO in the pool).
VMs=(
  "surrealdb|surrealdb-vm"
  "postgres|postgres-vm"
  "penpot|penpot-vm"
  "monitoring|monitoring-vm"
  "aspire|aspire-vm"
  "ca|ca-vm"
  "registry|registry-vm"
)

for row in "${VMs[@]}"; do
  IFS='|' read -r key dom <<<"$row"
  imp "module.${key}.libvirt_volume.disk"       "${POOL_DIR}/${dom}.qcow2"
  imp "module.${key}.libvirt_volume.cloudinit"  "${POOL_DIR}/${dom}-cloudinit.iso"
  uuid="$(virsh domuuid "${dom}")"
  imp "module.${key}.libvirt_domain.vm"          "${uuid}"
done

# dns uses for_each, so its addresses include the map key.
for k in dns dns2; do
  dom="${k}-vm"
  imp "module.dns[\"${k}\"].libvirt_volume.disk"       "${POOL_DIR}/${dom}.qcow2"
  imp "module.dns[\"${k}\"].libvirt_volume.cloudinit"  "${POOL_DIR}/${dom}-cloudinit.iso"
  uuid="$(virsh domuuid "${dom}")"
  imp "module.dns[\"${k}\"].libvirt_domain.vm"          "${uuid}"
done

echo "=== import done; state list ==="
tofu state list
