# Scaffolding for the local (default) libvirt provider — only created when
# var.vms is non-empty (used for local/dev testing).  The real VMs run on the
# vhost provider via services.tf/infra.tf.
resource "libvirt_pool" "vms" {
  count = length(var.vms) > 0 ? 1 : 0

  name = var.pool_name
  type = "dir"

  target = {
    path = var.pool_path
  }
}

# Base cloud image, downloaded into the pool from var.base_image_url.
# 0.9.x replaces the top-level source/format attributes with:
#   target   = { format = { type } }
#   create   = { content = { url } }  (capacity auto-computed from Content-Length)
# `create` is a provider-specific upload directive (not backed by libvirt XML)
# so it is absent from state after import.  0.9.x volumes cannot be updated
# in-place; ignore all post-import drift.
resource "libvirt_volume" "base" {
  count = length(var.vms) > 0 ? 1 : 0

  name = "fedora-cloud-base.qcow2"
  pool = libvirt_pool.vms[0].name

  target = {
    format = {
      type = "qcow2"
    }
  }

  create = {
    content = {
      url = var.base_image_url
    }
  }

  lifecycle {
    ignore_changes = all
  }
}

module "vm" {
  source = "./modules/vm"

  for_each = var.vms

  name             = each.key
  pool_name        = libvirt_pool.vms[0].name
  base_volume_path = libvirt_volume.base[0].path
  vcpu             = each.value.vcpu
  memory_mib       = each.value.memory_mib
  disk_gib         = each.value.disk_gib
  network_name     = var.network_name
  firmware         = var.uefi_firmware
  nvram_template   = var.uefi_nvram_template
  vm_user          = var.vm_user
  ssh_public_key   = trimspace(file(pathexpand(var.ssh_public_key_path)))
  containers       = each.value.containers
}
