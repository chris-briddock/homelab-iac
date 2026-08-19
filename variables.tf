variable "libvirt_uri" {
  description = "libvirt connection URI"
  type        = string
  default     = "qemu:///system"
}

# Passphrase for OpenTofu state/plan encryption (PBKDF2 -> AES-GCM). Supply via
# the TF_VAR_tf_encryption_passphrase env var; never commit it. Sensitive so it
# is not echoed in plans/output.
variable "tf_encryption_passphrase" {
  description = "Passphrase for OpenTofu state/plan encryption (supply via TF_VAR_tf_encryption_passphrase)"
  type        = string
  sensitive   = true
}

variable "pool_name" {
  description = "Name of the libvirt storage pool used for VM disks"
  type        = string
  default     = "tofu-vms"
}

variable "pool_path" {
  description = "Host filesystem path backing the storage pool"
  type        = string
  default     = "/var/lib/libvirt/images/tofu-vms"
}

variable "base_image_url" {
  description = "URL of the Fedora Cloud qcow2 base image"
  type        = string
  default     = "https://download.fedoraproject.org/pub/fedora/linux/releases/44/Cloud/x86_64/images/Fedora-Cloud-Base-Generic-44-1.7.x86_64.qcow2"
}

variable "network_name" {
  description = "Name of the libvirt network to attach VMs to (must already exist, e.g. the default NAT network)"
  type        = string
  default     = "default"
}

variable "ssh_public_key_path" {
  description = "Path to the SSH public key injected into VMs via cloud-init"
  type        = string
  default     = "~/.ssh/fedora_deploy_ed25519.pub"
}

variable "vm_user" {
  description = "Default cloud-init user created on each VM"
  type        = string
  default     = "fedora"
}

variable "vhost_host" {
  description = "IP/hostname of the remote KVM host for real services"
  type        = string
  default     = "192.168.70.1"
}

variable "vhost_ssh_user" {
  description = "SSH user for connecting to the vhost's libvirtd"
  type        = string
  default     = "deploy"
}

variable "vhost_ssh_keyfile" {
  description = "SSH private key used to connect to the vhost"
  type        = string
  default     = "~/.ssh/fedora_deploy_ed25519"
}

variable "vhost_bridge" {
  description = "Bridge interface on the vhost that VMs attach to for real LAN IPs"
  type        = string
  default     = "br0"
}

variable "vhost_socket_path" {
  description = "Local unix socket path proxying to the vhost's libvirtd (see README runbook for the ncat/virt-ssh-helper proxy that must be running)"
  type        = string
  default     = "/tmp/vhost-libvirt.sock"
}

variable "vhost_lan_cidr_suffix" {
  description = "CIDR suffix for the vhost's LAN (br0), used for static VM addresses"
  type        = string
  default     = "/22"
}

variable "vhost_gateway" {
  description = "Gateway IP on the vhost's LAN"
  type        = string
  default     = "192.168.68.1"
}

variable "vhost_dns" {
  description = "DNS servers for static-IP VMs on the vhost's LAN"
  type        = list(string)
  default     = ["192.168.68.1", "1.1.1.1"]
}

variable "uefi_firmware" {
  description = "OVMF firmware code path (raw pflash build) present on both KVM hosts"
  type        = string
  default     = "/usr/share/edk2/ovmf/OVMF_CODE.fd"
}

variable "uefi_nvram_template" {
  description = "OVMF VARS template path used to seed per-VM NVRAM"
  type        = string
  default     = "/usr/share/edk2/ovmf/OVMF_VARS.fd"
}

variable "vms" {
  description = "Map of VMs to create, keyed by name"
  type = map(object({
    vcpu       = number
    memory_mib = number
    disk_gib   = number
    containers = list(object({
      name  = string
      image = string
      ports = optional(list(string), [])
    }))
  }))
  default = {}
}
