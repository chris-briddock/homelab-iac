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
  #
  # 0.9.x note: the new dialer system (internal/libvirt/dialers) does NOT
  # support the "+unix" transport — "unsupported transport: unix".  Use
  # the bare "qemu" scheme (no transport, no host) so the factory picks
  # newLocalDialer(), which reads the "socket" query parameter and
  # connects to the proxy socket directly.
  uri = "qemu:///system?socket=${var.vhost_socket_path}"
}
