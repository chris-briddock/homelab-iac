variable "name" {
  description = "VM/domain name"
  type        = string
}

variable "pool_name" {
  description = "libvirt storage pool to create the VM disk in"
  type        = string
}

variable "base_volume_path" {
  description = "Host filesystem path of the base cloud image qcow2 to use as the copy-on-write backing store"
  type        = string
}

variable "vcpu" {
  type = number
}

variable "memory_mib" {
  type = number
}

variable "disk_gib" {
  type = number
}

variable "network_name" {
  description = "libvirt network name to attach to (mutually exclusive with bridge)"
  type        = string
  default     = null
}

variable "bridge" {
  description = "Host bridge interface to attach to for real LAN IPs (mutually exclusive with network_name)"
  type        = string
  default     = null
}

variable "static_ip" {
  description = "Static IPv4 address in CIDR form (e.g. 192.168.70.10/22). Null means DHCP."
  type        = string
  default     = null
}

variable "gateway" {
  description = "Gateway IP, required when static_ip is set"
  type        = string
  default     = null
}

variable "dns" {
  description = "DNS server IPs, used when static_ip is set"
  type        = list(string)
  default     = []
}

variable "vm_user" {
  type = string
}

variable "ssh_public_key" {
  type = string
}

variable "machine" {
  description = "QEMU machine type; q35 is required for a sane UEFI setup (i440fx+EFI leaves cloud-init's ISO on a legacy IDE bus)"
  type        = string
  default     = "q35"
}

variable "primary_iface" {
  description = "Predictable name of the first NIC inside the guest (enp1s0 on q35, ens3 on i440fx)"
  type        = string
  default     = "enp1s0"
}

variable "firmware" {
  description = "Path to UEFI firmware code (OVMF) on the host; null boots legacy BIOS"
  type        = string
  default     = null
}

variable "nvram_template" {
  description = "Path to the OVMF VARS template used to seed this VM's NVRAM (required when firmware is set)"
  type        = string
  default     = null
}

variable "containers" {
  description = "Containers to run on this VM via podman quadlet"
  type = list(object({
    name        = string
    image       = string
    ports       = optional(list(string), [])
    environment = optional(map(string), {})
    volumes     = optional(list(string), [])
    command     = optional(string, "")
    # Overrides the image ENTRYPOINT (maps to quadlet Entrypoint= / podman
    # --entrypoint). Needed for images whose entrypoint ignores CMD args
    # (e.g. gitea/act_runner's `run.sh` runs `act_runner daemon` directly,
    # swallowing any Exec= command); setting this to "sh" lets `command`
    # run as the actual process.
    entrypoint = optional(string, "")
    depends_on = optional(list(string), [])
    extra_args = optional(list(string), [])
    user       = optional(string, "")
    # When true the generated unit is a Type=oneshot job (run once at boot,
    # RemainAfterExit) instead of a long-running Restart=always service.
    # Use for idempotent bootstrap sidecars (e.g. SQL init scripts).
    oneshot = optional(bool, false)
  }))
  default = []
}

variable "extra_files" {
  description = "Extra files to write onto the VM via cloud-init (e.g. prometheus.yml, grafana provisioning)"
  type = list(object({
    path        = string
    content     = string
    permissions = optional(string, "0644")
  }))
  default = []
}

variable "extra_packages" {
  description = "Additional OS packages to install via cloud-init on top of the baseline (podman, qemu-guest-agent)"
  type        = list(string)
  default     = []
}

variable "extra_runcmd" {
  description = "Additional runcmd entries appended after the baseline steps. Each entry is a list (argv form, run verbatim by cloud-init)."
  type        = list(list(string))
  default     = []
}

variable "auto_sync" {
  description = <<EOT
When true (default), a terraform_data resource with a local-exec provisioner
SSHes into the running VM after every cloud-init content change and pushes the
new config files + quadlet definitions live — WITHOUT rebooting the VM. This
makes `tofu apply` the single command for rolling out config changes to already-
provisioned VMs (no manual `cloud-init clean && reboot`).

Config-file-only changes are hot-reloaded (container gets a reload signal, zero
downtime). Container spec changes (image/env/ports/volumes) trigger a graceful
restart of ONLY the affected container (~2-5s, not the whole VM).

Set to false for VMs being destructively disk-replaced (`-replace` on the disk +
domain): a fresh boot runs cloud-init automatically, so the sync provisioner
would be redundant (and would race the boot).
EOT
  type        = bool
  default     = true
}

variable "ssh_private_key_path" {
  description = "Path to the SSH private key used by the auto-sync local-exec provisioner to reach the running VM. Must correspond to the public key injected via cloud-init (ssh_public_key_path)."
  type        = string
  default     = "~/.ssh/fedora_deploy_ed25519"
}

variable "watchdog" {
  description = <<EOT
When true (default), install a quadlet watchdog on this VM: a oneshot
systemd service + timer (every ~30s) that re-starts any long-running
(non-oneshot) quadlet container whose systemd unit is no longer active.

This closes the gap RefuseManualStop cannot: containers stopped via podman
directly (operator `podman stop`, the daily `podman auto-update` timer, OOM or
an exhausted start-limit) leave the generated systemd unit inactive/dead with
nothing to resurrect it — the container's own Restart=always only fires on a
crash while systemd still owns the process. The recovery ladder deliberately
prefers `systemctl start` (START is allowed over RefuseManualStop; only STOP is
refused), then falls back to direct `podman start`, then unit recreate.

Oneshot containers (Type=oneshot) are EXCLUDED: after they finish their unit
is correctly inactive and must never be restarted by the watchdog.

Set to false to opt a VM out entirely.
EOT
  type        = bool
  default     = true
}
