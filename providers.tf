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

# OpenBao (api-compatible with HashiCorp Vault).
#
# - address: caddy-fronted TLS; ACME cert issued by step-ca for openbao.lab.internal
# - ca_cert_file: lab root CA; pins trust so the provider never silently falls
#   back to system roots or fails the handshake by surprise.
# - token: a TF_VAR, sensitive. The ROOT token passes through exactly once
#   here for the Phase A wiring; rotate it via the recovery-key flow right
#   after the apply succeeds. After that, this variable can be set to any
#   scoped admin token.
# - skip_child_token: don't mint child tokens per call; uses the provider
#   token directly so revocation is trivial.
provider "vault" {
  address          = "https://openbao.${local.internal_domain}"
  ca_cert_file     = "${path.module}/pki/root-ca.crt"
  token            = var.openbao_root_token
  skip_child_token = true
}
