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
    depends_on  = optional(list(string), [])
    extra_args  = optional(list(string), [])
    user        = optional(string, "")
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
