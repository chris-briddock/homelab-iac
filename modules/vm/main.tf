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
    extra_files    = local.all_extra_files
    iface          = var.primary_iface
    dns            = var.dns
    extra_packages = var.extra_packages
    extra_runcmd   = local.all_extra_runcmd
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
  # replacement, and -replace on this resource is the documented way to roll
  # new cloud-init content onto an existing VM (README workflow).  Unlike the
  # root disk below, drift here comes only from the auto-populated allocation
  # field on import; `allocation` is provider-computed-only so tofu genuinely
  # cannot manage it, and ignoring it would have been pointless anyway.  The
  # create.content.url directive MUST NOT be ignored — ignoring all also made
  # the provider skip re-uploading the new ISO bytes during a replace, which
  # on 2026-08-31 left the pool volume serving a stale user-data string to
  # every guest (diagnosed on dns-vm: instance-id matched previous-instance-id
  # and /dev/sr0 was byte-for-byte the pre-edit ISO even after a tofu
  # -replace).
  #
  # No ignore_changes here; `target = {}` on the resource matches what
  # libvirt reports back, so no drift to suppress.
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
# Zero-downtime config sync: when cloud-init content changes on an already-
# running VM, this terraform_data resource fires (triggers_replace on the
# config content hash) and SSHes into the VM to push the new config files +
# quadlet definitions live — WITHOUT rebooting the VM. This is the "second
# delivery path" alongside cloud-init (first boot). See sync.sh.tmpl.
#
# Config-file-only changes are hot-reloaded (container gets a SIGHUP or
# reload signal). Container spec changes (image/env/ports/volumes) trigger a
# graceful restart of ONLY the affected container (~2-5s, not the whole VM).
# Caddy is special: it always restarts (not reloads) because `caddy reload`
# does not trigger ACME cert issuance for new domains. No change = no-op
# (the sync script hash-compares every file before writing/restarting).
#
# Disabled when var.auto_sync = false (e.g., during destructive disk replaces
# where a fresh boot runs cloud-init automatically). Also disabled when the VM
# has no static IP (DHCP) since the provisioner can't reliably reach it.
# ---------------------------------------------------------------------------
locals {
  # Pre-render and base64-encode ALL file content here in HCL (where heredocs
  # and interpolation work correctly), then pass the base64 strings to the
  # sync script template. The sync script only decodes and writes — no
  # content building, no heredocs, no shell escaping. This mirrors the same
  # rendering as user-data.yaml.tmpl (single source of truth).

  # systemd-resolved drop-in (same content as cloud-init write_files).
  sync_resolved_content = <<-EOT
    [Resolve]
    %{~for d in var.dns~}
    %{~if can(regex("^192\\.168\\.", d))~}
    DNS=${d}
    %{~endif~}
    %{~endfor~}
    Domains=lab.internal
    %{~if length([for d in var.dns : d if !can(regex("^192\\.168\\.", d))]) > 0~}
    FallbackDNS=${join(" ", [for d in var.dns : d if !can(regex("^192\\.168\\.", d))])}
    %{~endif~}
  EOT

  # vmnet.network file (same content as cloud-init write_files).
  sync_vmnet_content = <<-EOT
    [Network]
    %{~if length(var.dns) > 0~}
    %{~for d in var.dns~}
    DNS=${d}
    %{~endfor~}
    %{~endif~}
  EOT

  # Per-container quadlet .container content. `content` (plain) is the single
  # source of truth: the live quadlet file, the sync-path quadlet (via `b64`
  # below) and the watchdog backup file are ALL derived from this one
  # rendering, so they can never drift apart. HCL locals cannot be user-defined
  # functions, so the rendering lives in the for-expression here and `b64` is
  # folded in as a second pass (see `sync_containers` below) rather than via a
  # lambda.
  _sync_containers_plain = [
    for c in var.containers : {
      name    = c.name
      oneshot = c.oneshot
      content = join("\n", concat(
        ["[Unit]",
          "Description=${c.name} container (managed by podman quadlet)",
          "After=network-online.target",
        "Wants=network-online.target"],
        [for d in c.depends_on : "Wants=${d}.service\nAfter=${d}.service"],
        ["RefuseManualStop=yes", "", "[Container]",
          "Image=${c.image}",
          "ContainerName=${c.name}",
        "Network=vmnet.network"],
        [for p in c.ports : "PublishPort=${p}"],
        [for k, v in c.environment : "Environment=${k}=\"${v}\""],
        [for vol in c.volumes : "Volume=${vol}"],
        [for a in c.extra_args : "PodmanArgs=${a}"],
        [c.user != "" ? "User=${c.user}" : ""],
        [c.entrypoint != "" ? "Entrypoint=${c.entrypoint}" : ""],
        [c.command != "" ? "Exec=${c.command}" : ""],
        ["AutoUpdate=registry", "", "[Service]"],
        [c.oneshot ? "Type=oneshot\nRemainAfterExit=yes" : "Restart=always"],
        ["TimeoutStartSec=900", "", "[Install]", "WantedBy=multi-user.target", ""],
      ))
    }
  ]

  # Sync-script view of the plain list: same objects plus `b64`, encoded from
  # the exact same `content` string the backup file uses (single rendering).
  sync_containers = [
    for sc in local._sync_containers_plain : merge(sc, {
      b64 = base64encode(sc.content)
    })
  ]

  # extra_files with pre-encoded content (add b64 field for the sync script).
  # Uses local.all_extra_files (var.extra_files + watchdog files) so the live
  # sync path and cloud-init stay identical.
  sync_extra_files = [
    for f in local.all_extra_files : {
      path        = f.path
      b64         = base64encode(f.content)
      permissions = f.permissions
    }
  ]

  # -------------------------------------------------------------------------
  # Quadlet watchdog (self-healing for stopped containers).
  #
  # Containers dropped via podman directly (operator `podman stop`, the daily
  # `podman auto-update` timer, OOM, or an exhausted start limit) leave the
  # generated systemd unit inactive/dead with nothing to bring it back —
  # the unit's own `Restart=always` only fires while systemd owns the process.
  # `RefuseManualStop=yes` in every generated quadlet blocks systemd's STOP
  # path, so a naïve watchdog that only polls `is-active` then `systemctl start`
  # would hammer a unit systemd refuses to touch. The recovery ladder below is
  # ordered to stay inside what RefuseManualStop permits on modern systemd:
  #   START is allowed over RefuseManualStop (only STOP is refused), so prefer
  #   `systemctl start` -> fall back to direct `podman start` -> recreate.
  #
  # One shell script + a oneshot service + a 30s timer, all rendered once and
  # delivered through BOTH paths (cloud-init write_files + the live sync), so
  # rollout is just `tofu apply`. Oneshot containers are excluded everywhere —
  # after they finish their unit is correctly inactive.
  # -------------------------------------------------------------------------

  # The long-running (non-oneshot) container names this VM watches. Rendered
  # into the service's ExecStart so `systemctl cat quadlet-watchdog.service`
  # shows exactly which containers are watched (single source of truth stays
  # in var.containers).
  watchdog_container_names = [for c in var.containers : c.name if !c.oneshot]

  # Space-separated name list for the ExecStart line (empty-safe).
  watchdog_names_arg = join(" ", local.watchdog_container_names)

  # The watchdog shell script. Runs as root via the systemd unit. NO `set -e`:
  # a single unit's failure must never abort the whole run — every container
  # gets its own recovery attempt, and logging happens to the journal via
  # `logger` so recoveries are observable with `journalctl -t quadlet-watchdog`.
  watchdog_script_content = <<-EOS
    #!/bin/bash
    # quadlet-watchdog: re-start long-running podman quadlet containers whose
    # systemd unit is no longer active; AND, if a quadlet .container file was
    # deleted, restore it verbatim from a protected backup.
    #
    # Oneshot bootstrap sidecars are filtered out by HCL everywhere — after
    # they finish their unit is correctly inactive; they must not restart.
    #
    # Two recovery stages, both strictly non-destructive:
    #   STAGE A (quadlet file missing -> restore from backup):
    #     - live at /etc/containers/systemd/<name>.container (the generator's
    #       source). If absent, copy the backup at
    #       /etc/infra/quadlet-backups/<name>.container (a byte-for-byte copy
    #       written at the same time as the live file, in a *different dir* so
    #       an `rm /etc/containers/systemd/...` never reaches it), then
    #       daemon-reload + systemctl enable --now so the unit re-registers.
    #       The sync script also repopulates the backup whenever it pushes new
    #       quadlet content, so backup==live always.
    #   STAGE B (unit not active -> start; stays within RefuseManualStop
    #     allowances — START is allowed, only STOP is refused):
    #     1. systemctl start <unit>   -> also retries a `failed` unit post-backoff.
    #     2. podman start <name>      -> starts the EXISTING container (same
    #                                  volume + podman IP, NO recreation).
    #     both fail -> log -p err; never `podman rm`.
    set -uo pipefail

    tag="quadlet-watchdog"
    BACKUP_DIR=/etc/infra/quadlet-backups

    for name in "$@"; do
      [ -z "$name" ] && continue
      service="$${name}.service"
      live="/etc/containers/systemd/$${name}.container"
      backup="$BACKUP_DIR/$${name}.container"

      # --- STAGE A: restore a deleted quadlet file ----------------------------
      if [ ! -f "$live" ]; then
        if [ -f "$backup" ]; then
          logger -t "$tag" "watchdog: quadlet deleted; restoring $service from backup"
          install -D -m 0644 "$backup" "$live" 2>/dev/null || true
          systemctl daemon-reload 2>/dev/null || true
          # After daemon-reload the unit is known to systemd again; enable+start
          # registers and brings it up in one step (enable --now is idempotent).
          systemctl enable --now "$service" 2>/dev/null || true
        else
          logger -t "$tag" -p err "watchdog: $live deleted and NO backup exists; manual intervention required"
        fi
      fi

      # --- STAGE B: start any non-active unit (existing container untouched) --
      if systemctl is-active --quiet "$service"; then
        continue
      fi
      logger -t "$tag" "watchdog: $service not active; attempting recovery"
      if systemctl start "$service" 2>/dev/null; then
        logger -t "$tag" "watchdog: recovered via systemctl start: $service"
      elif podman start "$name" 2>/dev/null; then
        logger -t "$tag" "watchdog: recovered via podman start: $name"
      else
        logger -t "$tag" -p err "watchdog: FAILED to recover $service; leaving container untouched (manual intervention required)"
      fi
    done
  EOS

  # systemd oneshot service. Argument list => the VM's watch targets are baked
  # in (readable via `systemctl cat`). No [Install]: driven solely by the timer.
  watchdog_service_content = <<-EOS
    [Unit]
    Description=Podman quadlet watchdog (re-start long-running containers that left systemd's control)
    After=podman.service
    Wants=podman.service

    [Service]
    Type=oneshot
    ExecStart=/usr/local/sbin/quadlet-watchdog.sh ${local.watchdog_names_arg}
  EOS

  # systemd timer at ~30s cadence. Persistent=true catches up after any timer
  # downtime; OnBootSec gives the first check ~1 min after boot (letting quadlets
  # settle) so the watchdog doesn't fight podman during the initial bring-up.
  watchdog_timer_content = <<-EOS
    [Unit]
    Description=Podman quadlet watchdog timer (${var.name})

    [Timer]
    OnBootSec=60s
    OnUnitActiveSec=30s
    Persistent=true

    [Install]
    WantedBy=timers.target
  EOS

  # The three files, only when this VM has watchdog-worthy containers and the
  # feature is enabled. Oneshot-only / no-container / watchdog=false VMs get
  # no files and no activation commands.
  watchdog_enabled = var.watchdog && length(local.watchdog_container_names) > 0

  # Protected, byte-for-byte backup of each non-oneshot quadlet file. Stored
  # OUTSIDE /etc/containers/systemd so any `rm` of the quadlet dir can't reach
  # it; the watchdog restores from here when a quadlet goes missing. The plain
  # (unencoded) content comes from local.sync_containers' `content` field —
  # the same rendering used for the live quadlet file (single source of truth).
  # Oneshot sidecars are intentionally NOT backed up: they only run at boot,
  # and the watchdog must never restart them.
  watchdog_quada_backup_files = !local.watchdog_enabled ? [] : [
    for sc in local.sync_containers : {
      path        = "/etc/infra/quadlet-backups/${sc.name}.container"
      content     = sc.content
      permissions = "0644"
    } if !sc.oneshot
  ]

  all_extra_files = concat(var.extra_files, !local.watchdog_enabled ? [] : concat(
    [
      { path = "/usr/local/sbin/quadlet-watchdog.sh", content = local.watchdog_script_content, permissions = "0755" },
      { path = "/etc/systemd/system/quadlet-watchdog.service", content = local.watchdog_service_content, permissions = "0644" },
      { path = "/etc/systemd/system/quadlet-watchdog.timer", content = local.watchdog_timer_content, permissions = "0644" },
    ],
    local.watchdog_quada_backup_files,
  ))

  # Activation: after the files land (cloud-init write_files then runcmd, or
  # the sync path's extra_files writer then this runcmd), register the units
  # and start the timer. `enable --now` is idempotent.
  all_extra_runcmd = concat(var.extra_runcmd, !local.watchdog_enabled ? [] : [
    ["systemctl", "daemon-reload"],
    ["systemctl", "enable", "--now", "quadlet-watchdog.timer"],
  ])

  # Render the sync script. All content is base64-encoded above; the script
  # only decodes and writes. Base64-encode the whole script too so the
  # local-exec command can decode it without shell-escaping issues.
  # Uses local.all_extra_runcmd (var.extra_runcmd + watchdog activation) so the
  # watchdog timer gets enabled on the live-sync path too.
  sync_script_b64 = base64encode(templatefile("${path.module}/sync.sh.tmpl", {
    containers   = local.sync_containers
    extra_files  = local.sync_extra_files
    extra_runcmd = local.all_extra_runcmd
    resolved_b64 = base64encode(local.sync_resolved_content)
    vmnet_b64    = base64encode(local.sync_vmnet_content)
  }))
}

resource "terraform_data" "config_sync" {
  count = var.auto_sync && var.static_ip != null ? 1 : 0

  # Fire ONLY when the config content actually changes — not on every plan.
  # The hash covers containers (image/env/ports/volumes/quadlet spec),
  # extra_files (all config files), and extra_runcmd (one-time setup).
  triggers_replace = [
    sha256(jsonencode(var.containers)),
    sha256(jsonencode(local.all_extra_files)),
    sha256(jsonencode(local.all_extra_runcmd)),
  ]

  # The cloud-init ISO must be uploaded to the pool before we push the same
  # content live (in case of a first-boot race where cloud-init hasn't run
  # yet — the sync script is idempotent and safe to run in parallel).
  depends_on = [
    libvirt_volume.cloudinit,
    libvirt_domain.vm,
  ]

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    # The sync script is base64-encoded in HCL (sync_script_b64 above) to
    # avoid all shell-escaping issues — the script contains $, $(, <<, [[,
    # etc. which would be mangled by nested heredocs or HCL interpolation.
    # At runtime: decode to a temp file, then pipe it over SSH to the VM
    # where it runs as root (sudo bash -s). A bounded retry loop handles the
    # first-boot race where the VM is still coming up.
    #
    # NOTE: $VM_IP and $tries are intentionally unescaped (single $) because
    # they are runtime shell variables, NOT HCL interpolations. The HCL
    # interpolations (${var...}, ${local...}) are resolved at plan time and
    # produce literal strings in the command.
    command = <<-EOT
      set -e
      VM_IP="$(python3 -c "import sys; print(sys.argv[1].split('/')[0])" '${var.static_ip}')"
      TMP_SCRIPT="$(mktemp /tmp/vm-sync-XXXXXX.sh)"
      printf '%s' '${local.sync_script_b64}' | base64 -d > "$TMP_SCRIPT"
      chmod 600 "$TMP_SCRIPT"
      tries=0
      until ssh -o ConnectTimeout=10 -o StrictHostKeyChecking=no \
          -o UserKnownHostsFile=/dev/null -o UpdateHostkeys=no \
          -i "${pathexpand(var.ssh_private_key_path)}" \
          "${var.vm_user}@$VM_IP" \
          "sudo bash -s" < "$TMP_SCRIPT"; do
        tries=$((tries + 1))
        if [ "$tries" -ge 12 ]; then
          echo "sync: failed to reach $VM_IP after $tries attempts" >&2
          rm -f "$TMP_SCRIPT"
          exit 1
        fi
        echo "sync: $VM_IP not ready (attempt $tries/12), retrying in 10s..."
        sleep 10
      done
      rm -f "$TMP_SCRIPT"
    EOT
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
