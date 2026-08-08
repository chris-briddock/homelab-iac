output "name" {
  value = libvirt_domain.vm.name
}

# In 0.9.x the network interface addresses are no longer surfaced as a flat
# list on the domain; they live under devices.interfaces[*] and are only
# populated when wait_for_ip is set.  Static IPs are known up-front from the
# cloud-init config, so prefer that.  DHCP VMs rely on wait_for_ip and the
# provider does not expose the resolved address as a public attribute yet.
output "ipv4" {
  value = var.static_ip != null ? split("/", var.static_ip)[0] : null
}
