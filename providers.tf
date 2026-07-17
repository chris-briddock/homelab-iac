provider "libvirt" {
  uri = var.libvirt_uri
}

provider "libvirt" {
  alias = "vhost"
  # A real qemu+ssh:// connection from this provider hits a bug in its
  # (statically-linked, non-cgo) SSH transport ("Cannot find start time for
  # pid ..."); worked around by proxying through a local unix socket that
  # spawns the same virt-ssh-helper mechanism virsh uses successfully
  # (see README runbook for how the proxy is started).
  uri = "qemu+unix:///system?socket=${var.vhost_socket_path}"
}
