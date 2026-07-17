resource "libvirt_volume" "disk" {
  name           = "${var.name}.qcow2"
  pool           = var.pool_name
  base_volume_id = var.base_volume_id
  size           = var.disk_gib * 1024 * 1024 * 1024
  format         = "qcow2"
}

resource "libvirt_cloudinit_disk" "init" {
  name           = "${var.name}-cloudinit.iso"
  pool           = var.pool_name
  user_data      = templatefile("${path.module}/../../cloud-init/user-data.yaml.tmpl", {
    hostname       = var.name
    vm_user        = var.vm_user
    ssh_public_key = var.ssh_public_key
    containers     = var.containers
    extra_files    = var.extra_files
    iface          = var.primary_iface
    dns            = var.dns
  })
  network_config = templatefile("${path.module}/../../cloud-init/network-config.yaml.tmpl", {
    static_ip = var.static_ip
    gateway   = var.gateway
    dns       = var.dns
    iface     = var.primary_iface
  })
}

resource "libvirt_domain" "vm" {
  name       = var.name
  memory     = var.memory_mib
  vcpu       = var.vcpu
  machine    = var.machine
  qemu_agent = true

  cloudinit = libvirt_cloudinit_disk.init.id

  xml {
    xslt = file("${path.module}/cdrom-sata.xsl")
  }

  firmware = var.firmware

  dynamic "nvram" {
    for_each = var.nvram_template == null ? [] : [var.nvram_template]
    content {
      file     = "/var/lib/libvirt/qemu/nvram/${var.name}_VARS.fd"
      template = nvram.value
    }
  }

  cpu {
    mode = "host-passthrough"
  }

  network_interface {
    network_name   = var.bridge == null ? var.network_name : null
    bridge         = var.bridge
    wait_for_lease = var.static_ip == null
  }

  disk {
    volume_id = libvirt_volume.disk.id
  }

  console {
    type        = "pty"
    target_type = "serial"
    target_port = "0"
  }

  graphics {
    type        = "spice"
    listen_type = "address"
    autoport    = true
  }
}
