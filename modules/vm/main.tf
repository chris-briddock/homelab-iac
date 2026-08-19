# ---------------------------------------------------------------------------
# Cloud-init ISO: 0.9.x only generates the file on disk; we upload it as a
# libvirt_volume and attach it to the domain as a cdrom in the disk list.
# ---------------------------------------------------------------------------
resource "libvirt_cloudinit_disk" "init" {
  name = "${var.name}-cloudinit"

  user_data = templatefile("${path.module}/../../cloud-init/user-data.yaml.tmpl", {
    hostname       = var.name
    vm_user        = var.vm_user
    ssh_public_key = var.ssh_public_key
    containers     = var.containers
    extra_files    = var.extra_files
    iface          = var.primary_iface
    dns            = var.dns
    extra_packages = var.extra_packages
    extra_runcmd   = var.extra_runcmd
  })

  meta_data = yamlencode({
    instance-id    = var.name
    local-hostname = var.name
  })

  network_config = templatefile("${path.module}/../../cloud-init/network-config.yaml.tmpl", {
    static_ip = var.static_ip
    gateway   = var.gateway
    dns       = var.dns
    iface     = var.primary_iface
  })
}

# Upload the generated cloud-init ISO into the libvirt pool so it can be
# attached as a cdrom. 0.9.x libvirt_cloudinit_disk no longer creates a
# libvirt volume itself; it only writes the ISO to a local path.
resource "libvirt_volume" "cloudinit" {
  name = "${var.name}-cloudinit.iso"
  pool = var.pool_name

  # Do NOT declare target.format.type here. libvirt fills the volume XML's
  # <format> by probing the uploaded bytes, and for a small cloud-init ISO it
  # nondeterministically reports "iso" (detected ISO9660 signature) or "raw"
  # (small file / sparse / refresh race). Both a fixed "iso" and a fixed "raw"
  # therefore produce 'Provider produced inconsistent result after apply' on
  # roughly half the creates. Omitting the format leaves nothing to contradict
  # and the create-upload path still writes the ISO onto a raw volume, which
  # the guest attaches as a cdrom below.
  target = {}

  create = {
    content = {
      url = libvirt_cloudinit_disk.init.path
    }
  }

  # 0.9.x volumes cannot be updated in-place — any change forces
  # replacement.  This cloudinit ISO was imported from the running VM;
  # ignore all post-import drift (auto-populated allocation, target
  # permissions/timestamps, and the `create` upload directive which is
  # absent from state after import).
  lifecycle {
    ignore_changes = all
  }
}

# ---------------------------------------------------------------------------
# Root disk: qcow2 overlay on the base cloud image (copy-on-write clone).
# 0.9.x replaces base_volume_id with backing_store = { path, format } and
# replaces the top-level format attribute with target = { format = { type } }.
# ---------------------------------------------------------------------------
resource "libvirt_volume" "disk" {
  name     = "${var.name}.qcow2"
  pool     = var.pool_name
  capacity = var.disk_gib * 1024 * 1024 * 1024

  target = {
    format = {
      type = "qcow2"
    }
  }

  backing_store = {
    path = var.base_volume_path
    format = {
      type = "qcow2"
    }
  }

  # 0.9.x volumes cannot be updated in-place.  This root disk was imported
  # from the running VM; ignore all post-import drift (auto-populated
  # allocation, physical, target permissions/timestamps/cluster_size).
  lifecycle {
    ignore_changes = all
  }
}

# ---------------------------------------------------------------------------
# Domain (VM). 0.9.x uses nested objects instead of repeated blocks:
#   os       -> local.os_config (conditional UEFI or plain BIOS)
#   cpu      -> local.cpu_config (host-passthrough, check=none, migratable)
#   devices  -> { disks, interfaces, channels, consoles, graphics }
#
# The root disk source references the libvirt volume by pool+name (XML
# type='volume') to match the running VMs.  The cloud-init ISO is a SATA
# cdrom (q35 has no IDE bus); the old xml { xslt = ... } override is gone
# in 0.9.x, so bus/dev are set directly in the disk target object.
# ---------------------------------------------------------------------------
resource "libvirt_domain" "vm" {
  name        = var.name
  type        = "kvm"
  memory      = var.memory_mib
  memory_unit = "MiB"
  vcpu        = var.vcpu
  running     = true
  autostart   = true

  os       = local.os_config
  cpu      = local.cpu_config
  features = local.features_config

  devices = {
    disks = concat(
      [{
        # driver.type MUST be "qcow2": the root volumes are qcow2 overlays on
        # the base cloud image. If omitted, libvirt defaults the QEMU driver
        # to type='raw', so QEMU reads the qcow2 header as a raw sector —
        # no partition table / ESP — and UEFI reports "No bootable option".
        driver = {
          name = "qemu"
          type = "qcow2"
        }
        source = {
          volume = {
            pool   = var.pool_name
            volume = libvirt_volume.disk.name
          }
        }
        target = {
          dev = "vda"
          bus = "virtio"
        }
      }],
      [{
        # Cloud-init ISO as a SATA cdrom (q35 has no IDE bus).
        device    = "cdrom"
        read_only = true
        serial    = "cloudinit"
        source = {
          file = {
            file = libvirt_volume.cloudinit.target.path
          }
        }
        target = {
          dev = "sda"
          bus = "sata"
        }
      }],
    )

    interfaces = [
      {
        model = {
          type = "virtio"
        }
        # Single object literal (not a ternary) so the type is uniform
        # regardless of whether we use a bridge or a libvirt network —
        # HCL would otherwise try to unify the two ternary branches and
        # validate required fields across every union variant in `source`.
        source = {
          network = var.bridge == null ? { network = var.network_name } : null
          bridge  = var.bridge == null ? null : { bridge = var.bridge }
        }
        wait_for_ip = var.static_ip == null ? {
          timeout = 300
        } : null
      },
    ]

    # qemu-guest-agent channel: enables graceful shutdown, IP reporting,
    # and `virsh qemu-agent-command` from the host.
    channels = [
      {
        source = {
          unix = {
            mode = "bind"
          }
        }
        target = {
          virt_io = {
            name = "org.qemu.guest_agent.0"
          }
        }
      },
    ]

    consoles = [
      {
        target = {
          type = "serial"
          port = 0
        }
      },
    ]

    graphics = [
      {
        spice = {
          auto_port = true
          listen    = "127.0.0.1"
        }
      },
    ]
  }
}

# ---------------------------------------------------------------------------
# Locals: build the os and cpu objects conditionally so that UEFI firmware
# fields only appear when var.firmware is set (legacy BIOS otherwise).
# The UEFI fields mirror the running VMs' libvirt XML exactly:
#   <os firmware='efi'>
#     <loader readonly='yes' secure='no' type='pflash' format='raw'>...</loader>
#     <nvram template='...' templateFormat='raw' format='raw'>...</nvram>
#     <firmware><feature enabled='no' name='enrolled-keys'/>
#               <feature enabled='no' name='secure-boot'/></firmware>
#   </os>
# ---------------------------------------------------------------------------
locals {
  # Built as a single object literal so the type is uniform regardless of
  # whether UEFI is in use (HCL conditionals require both branches to share
  # the same object shape).  When var.firmware is null the UEFI fields are
  # set to null and omitted from the rendered XML by the provider.
  os_config = {
    type            = "hvm"
    type_arch       = "x86_64"
    type_machine    = var.machine
    boot_devices    = [{ dev = "hd" }]
    firmware        = var.firmware == null ? null : "efi"
    loader          = var.firmware
    loader_readonly = var.firmware == null ? null : "yes"
    loader_type     = var.firmware == null ? null : "pflash"
    loader_format   = var.firmware == null ? null : "raw"
    loader_secure   = var.firmware == null ? null : "no"
    firmware_info = var.firmware == null ? null : {
      features = [
        { enabled = "no", name = "enrolled-keys" },
        { enabled = "no", name = "secure-boot" },
      ]
    }
    nv_ram = (var.firmware == null || var.nvram_template == null) ? null : {
      nv_ram          = "/var/lib/libvirt/qemu/nvram/${var.name}_VARS.fd"
      template        = var.nvram_template
      template_format = "raw"
      format          = "raw"
    }
  }

  # NOTE: `migratable` is intentionally OMITTED. The 0.9.x provider renders
  # booleans as 'yes'/'no' in the domain XML, but this libvirt version rejects
  # BOTH values with: "Invalid value for attribute 'migratable' in element
  # 'cpu': 'yes'" (or 'no'). The running VMs don't have the attribute set at
  # all, so omitting it matches state exactly and avoids the XML error.
  cpu_config = {
    mode  = "host-passthrough"
    check = "none"
  }

  # libvirt requires <features><acpi/></features> for UEFI firmware domains
  # ("unsupported configuration: UEFI requires ACPI on this architecture").
  # The running VMs all have acpi enabled. Boolean true renders as <acpi/>.
  features_config = {
    acpi = true
  }
}
