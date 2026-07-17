resource "libvirt_pool" "vms" {
  name = var.pool_name
  type = "dir"

  target {
    path = var.pool_path
  }
}

resource "libvirt_volume" "base" {
  name   = "fedora-cloud-base.qcow2"
  pool   = libvirt_pool.vms.name
  source = var.base_image_url
  format = "qcow2"
}

module "vm" {
  source = "./modules/vm"

  for_each = var.vms

  name           = each.key
  pool_name      = libvirt_pool.vms.name
  base_volume_id = libvirt_volume.base.id
  vcpu           = each.value.vcpu
  memory_mib     = each.value.memory_mib
  disk_gib       = each.value.disk_gib
  network_name   = var.network_name
  firmware       = var.uefi_firmware
  nvram_template = var.uefi_nvram_template
  vm_user        = var.vm_user
  ssh_public_key = trimspace(file(pathexpand(var.ssh_public_key_path)))
  containers     = each.value.containers
}
