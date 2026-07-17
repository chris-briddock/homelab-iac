output "name" {
  value = libvirt_domain.vm.name
}

output "ipv4" {
  value = var.static_ip != null ? split("/", var.static_ip)[0] : try(libvirt_domain.vm.network_interface[0].addresses[0], null)
}
