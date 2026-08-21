# ---------------------------------------------------------------------------
# Infra VMs: DNS (CoreDNS, lab.internal zone), CA (step-ca, internal ACME),
# and a docker.io pull-through registry cache.
# ---------------------------------------------------------------------------
locals {
  internal_domain = "lab.internal"

  # A records: every VM by name (dns/ca/registry are first-class entries in
  # service_ips), plus the KVM host itself.
  dns_a_records = merge(local.service_ips, {
    vhost = var.vhost_host
  })

  # CNAMEs for services that share a VM.
  dns_cname_records = {
    grafana    = "monitoring"
    prometheus = "monitoring"
    ntfy       = "monitoring"
  }

  # Both CoreDNS VMs serve identical copies of the zone.
  dns_vms = {
    dns  = local.service_ips.dns
    dns2 = local.service_ips.dns2
  }

  dns_ns_records = join("\n", [
    for name in sort(keys(local.dns_vms)) : "@ IN NS ${name}.${local.internal_domain}."
  ])

  dns_zone_records = join("\n", concat(
    [for name, ip in local.dns_a_records : "${name} IN A ${ip}"],
    [for name, target in local.dns_cname_records : "${name} IN CNAME ${target}.${local.internal_domain}."],
  ))

  # Reverse (PTR) zone for the 192.168.70.0/24 block the service IPs live in.
  # Each A record's last octet becomes the PTR owner name.
  dns_reverse_zone_name = "70.168.192.in-addr.arpa"

  dns_ptr_records = join("\n", [
    for name, ip in local.dns_a_records :
    "${element(split(".", ip), 3)} IN PTR ${name}.${local.internal_domain}."
  ])

  dns_reverse_zone_file = <<-EOT
    $ORIGIN ${local.dns_reverse_zone_name}.
    $TTL 300
    @ IN SOA dns.${local.internal_domain}. admin.${local.internal_domain}. 1 7200 3600 1209600 300
    ${local.dns_ns_records}
    ${local.dns_ptr_records}
  EOT

  # Zone content only changes via VM re-provision (cloud-init), so a static
  # serial is enough.
  dns_zone_file = <<-EOT
    $ORIGIN ${local.internal_domain}.
    $TTL 300
    @ IN SOA dns.${local.internal_domain}. admin.${local.internal_domain}. 1 7200 3600 1209600 300
    ${local.dns_ns_records}
    ${local.dns_zone_records}
  EOT

  coredns_corefile = <<-EOT
    # Bare zone blocks serve legacy plaintext DNS on :53 only. The DoH
    # listener below (https://.:8053) is a SEPARATE server block and must
    # declare its own `file` zones with an explicit zone argument -- CoreDNS
    # builds an independent plugin chain per server-block, so the lab.internal
    # zone loaded here does NOT cross over to the https block. A bare
    # `file /path` (no zone arg) inside https://.:8053 would wrongly bind the
    # file to the root zone "."; the explicit `file <path> lab.internal`
    # form is required so the authoritative data is served for DoH queries.
    ${local.internal_domain} {
        file /etc/coredns/${local.internal_domain}.zone
        prometheus 0.0.0.0:9153
        log
        errors
    }

    ${local.dns_reverse_zone_name} {
        file /etc/coredns/${local.dns_reverse_zone_name}.zone
        prometheus 0.0.0.0:9153
        log
        errors
    }

    . {
        # DoT to Cloudflare's anycast, authenticated by the well-known
        # tls_servername (not just PKI), so the upstream leg of every query
        # that leaves the lab is encrypted.
        forward . tls://1.1.1.1 tls://1.0.0.1 {
            tls_servername cloudflare-dns.com
        }
        cache 300
        prometheus 0.0.0.0:9153
        log
        errors
    }

    # Internal DoH listener for the caddy front-end pod. Caddy on :443
    # reverse-proxies HTTPS to this. The server-block zone is "." (root),
    # so the `file` directives MUST carry an explicit zone argument --
    # without it CoreDNS would bind the zone file to "." (wrong). With the
    # explicit zone, lab.internal and reverse-zone queries are answered
    # authoritatively over DoH; anything else falls through to `forward`
    # (upstream DoT to Cloudflare).
    https://.:8053 {
        file /etc/coredns/${local.internal_domain}.zone ${local.internal_domain}
        file /etc/coredns/${local.dns_reverse_zone_name}.zone ${local.dns_reverse_zone_name}
        forward . tls://1.1.1.1 tls://1.0.0.1 {
            tls_servername cloudflare-dns.com
        }
        cache 300
        prometheus 0.0.0.0:9153
        log
        errors
        tls /etc/coredns/doh-tls.crt /etc/coredns/doh-tls.key
    }
  EOT

  # DoH front-end for the two dns VMs. CoreDNS serves :53 for legacy clients
  # and :8053 for the internal DoH leg (self-signed TLS, HTTP traffic only
  # inside the podman user network). Caddy on :443 terminates TLS using an
  # ACME cert from our step-ca and reverse-proxies RFC 8484 /dns-query to
  # coredns:8053 — HTTPS between caddy and CoreDNS, so the DNS payload stays
  # encrypted end-to-end. The upstream cert is self-signed; tls_insecure_skip_verify
  # is safe because the network is private and caddy never validates the name.
  #
  # Each dns VM's Caddyfile contains ONLY its own site block — putting both
  # VMs' site blocks on one VM would have that VM's caddy try (and fail) to
  # ACME the other VM's cert, because tls-alpn-01 to the other name is
  # unreachable until the other VM's caddy is up. The dns_caddyfile function
  # is called per-instance via the `name` argument from the dns_vms for_each loop.
  dns_caddyfile_per_vm = {
    for name in sort(keys(local.dns_vms)) : name => <<-EOT
      ${name}.${local.internal_domain} {
          handle /dns-query* {
              reverse_proxy https://coredns:8053 {
                  transport http {
                      tls_insecure_skip_verify
                  }
              }
          }
          handle {
              respond "Not Found" 404
          }
          tls {
              issuer acme {
                  dir https://ca.${local.internal_domain}:9000/acme/acme/directory
                  trusted_roots /etc/caddy/root_ca.crt
              }
          }
      }
    EOT
  }

  step_ca_config = jsonencode({
    root     = "/home/step/certs/root_ca.crt"
    crt      = "/home/step/certs/intermediate_ca.crt"
    key      = "/home/step/secrets/intermediate_ca_key"
    address  = ":9000"
    dnsNames = ["ca.${local.internal_domain}", local.service_ips.ca]
    logger   = { format = "text" }
    db = {
      type       = "badgerv2"
      dataSource = "/home/step/db"
    }
    authority = {
      provisioners = [
        {
          type = "ACME"
          name = "acme"
          claims = {
            defaultTLSCertDuration = "720h"
            maxTLSCertDuration     = "2160h"
          }
        }
      ]
    }
    tls = { minVersion = 1.2 }
  })
}

# ---------------------------------------------------------------------------
# DNS VMs: two identical CoreDNS instances; every client lists both.
# ---------------------------------------------------------------------------
module "dns" {
  source    = "./modules/vm"
  providers = { libvirt = libvirt.vhost }

  for_each = local.dns_vms

  name             = "${each.key}-vm"
  pool_name        = libvirt_pool.vhost.name
  base_volume_path = libvirt_volume.base_vhost.path
  vcpu             = 2
  memory_mib       = 1024
  disk_gib         = 5
  bridge           = var.vhost_bridge
  static_ip        = "${each.value}${var.vhost_lan_cidr_suffix}"
  gateway          = var.vhost_gateway
  # These VMs host the DNS servers, so they must not resolve through
  # themselves (image pulls at first boot happen before CoreDNS is up).
  dns            = var.vhost_dns
  firmware       = var.uefi_firmware
  nvram_template = var.uefi_nvram_template
  vm_user        = var.vm_user
  ssh_public_key = trimspace(file(pathexpand(var.ssh_public_key_path)))

  # Self-signed TLS cert for CoreDNS's internal :8053 DoH listener (caddy
  # talks to it inside the podman network; never externally visible).
  # Generated once at cloud-init; caddy upstreams with
  # tls_insecure_skip_verify so the cert never needs renewal. openssl
  # writes the key mode-0600 root-only; chmod to 0644 because coredns
  # runs as a non-root uid inside the container and cannot otherwise read
  # it (the key is for an internal self-signed cert whose secrecy is not
  # part of the DoH security model -- the client-TLS trust boundary is
  # caddy's step-ca ACME cert on :443).
  extra_runcmd = [
    ["openssl", "req", "-x509", "-nodes", "-newkey", "rsa:2048",
      "-keyout", "/etc/infra/coredns/doh-tls.key",
      "-out", "/etc/infra/coredns/doh-tls.crt",
      "-days", "3650",
    "-subj", "/CN=coredns"],
    ["chmod", "644", "/etc/infra/coredns/doh-tls.key", "/etc/infra/coredns/doh-tls.crt"],
  ]

  extra_files = [
    { path = "/etc/infra/coredns/Corefile", content = local.coredns_corefile },
    { path = "/etc/infra/coredns/${local.internal_domain}.zone", content = local.dns_zone_file },
    { path = "/etc/infra/coredns/${local.dns_reverse_zone_name}.zone", content = local.dns_reverse_zone_file },
    { path = "/etc/infra/Caddyfile", content = local.dns_caddyfile_per_vm[each.key] },
    { path = "/etc/infra/root_ca.crt", content = local.root_ca_cert_pem },
    local.root_ca_anchor_file,
  ]

  containers = [
    {
      name  = "coredns"
      image = "docker.io/coredns/coredns:latest"
      # Port 53 must bind the LAN IP specifically: systemd-resolved's stub
      # listener on 127.0.0.53:53 makes a wildcard 0.0.0.0:53 publish fail.
      ports = [
        "${each.value}:53:53",
        "${each.value}:53:53/udp",
        "9153:9153",
      ]
      command = "-conf /etc/coredns/Corefile"
      # The doh-tls cert/key mounts are required by the tls directive in the
      # https://.:8053 block; without them CoreDNS fails to start the DoH
      # listener on a fresh build (the cert is generated by extra_runcmd).
      volumes = [
        "/etc/infra/coredns/Corefile:/etc/coredns/Corefile:Z",
        "/etc/infra/coredns/${local.internal_domain}.zone:/etc/coredns/${local.internal_domain}.zone:Z",
        "/etc/infra/coredns/${local.dns_reverse_zone_name}.zone:/etc/coredns/${local.dns_reverse_zone_name}.zone:Z",
        "/etc/infra/coredns/doh-tls.crt:/etc/coredns/doh-tls.crt:Z",
        "/etc/infra/coredns/doh-tls.key:/etc/coredns/doh-tls.key:Z",
      ]
    },
    {
      # DoH front for CoreDNS. Terminates TLS on :443 with a step-ca ACME
      # cert covering this VM's own <name>.lab.internal and reverse-proxies
      # RFC 8484 /dns-query to the coredns container by container-name DNS
      # on the shared vmnet network. Plain :53/udp+tcp on coredns stays
      # published for LAN clients that haven't moved to DoH yet.
      name  = "caddy"
      image = "docker.io/library/caddy:latest"
      # :80 is required for ACME http-01 validation: step-ca reaches
      # http://<name>.lab.internal:80/.well-known/acme-challenge/... from the
      # ca VM. (Earlier attempts with only 443:443 published saw caddy log
      # `trying to solve challenge http-01` and then stall forever because
      # step-ca had nothing to talk to on :80.)
      ports      = ["80:80", "443:443"]
      depends_on = ["coredns"]
      # The container's podman user-network upstreams aardvark-dns's
      # resolver for *lab-internal* names back to var.vhost_dns (LAN router
      # + 1.1.1.1), which doesn't know lab.internal. Static host entries
      # pin ca.lab.internal so caddy's ACME client can reach the CA without
      # needing DNS changes.
      extra_args = ["--add-host", "ca.lab.internal:192.168.70.18"]
      volumes = [
        "/etc/infra/Caddyfile:/etc/caddy/Caddyfile:Z",
        "/etc/infra/root_ca.crt:/etc/caddy/root_ca.crt:Z",
        "caddy-data:/data",
      ]
    },
    {
      name  = "node-exporter"
      image = "quay.io/prometheus/node-exporter:latest"
      ports = ["9100:9100"]
    },
  ]
}

# ---------------------------------------------------------------------------
# CA VM: step-ca (internal ACME)
# ---------------------------------------------------------------------------
module "ca" {
  source    = "./modules/vm"
  providers = { libvirt = libvirt.vhost }

  name             = "ca-vm"
  pool_name        = libvirt_pool.vhost.name
  base_volume_path = libvirt_volume.base_vhost.path
  vcpu             = 2
  memory_mib       = 1024
  disk_gib         = 5
  bridge           = var.vhost_bridge
  static_ip        = "${local.service_ips.ca}${var.vhost_lan_cidr_suffix}"
  gateway          = var.vhost_gateway
  dns              = local.vm_dns
  firmware         = var.uefi_firmware
  nvram_template   = var.uefi_nvram_template
  vm_user          = var.vm_user
  ssh_public_key   = trimspace(file(pathexpand(var.ssh_public_key_path)))

  extra_files = [
    { path = "/etc/infra/step/ca.json", content = local.step_ca_config },
    { path = "/etc/infra/step/root_ca.crt", content = local.root_ca_cert_pem },
    # Intermediate CA is a local file minted by scripts/gen-pki.sh (see
    # pki.tf); the key is git-ignored and lives only on the operator's
    # machine -- `sensitive()` keeps parity with how the old tls provider
    # attribute was marked, so the plan still redacts it.
    { path = "/etc/infra/step/intermediate_ca.crt", content = file("${path.module}/pki/intermediate-ca.crt") },
    {
      path        = "/etc/infra/step/intermediate_ca_key"
      content     = sensitive(file("${path.module}/pki/intermediate-ca.key"))
      permissions = "0600"
    },
    local.registry_mirror_file,
    local.root_ca_anchor_file,
  ]

  containers = [
    {
      name  = "step-ca"
      image = "docker.io/smallstep/step-ca:latest"
      ports = ["9000:9000"]
      # The image entrypoint sees the mounted config and just runs the CA;
      # the key is unencrypted so no --password-file is needed.
      command = "/usr/local/bin/step-ca /home/step/config/ca.json"
      # Mounted config/certs are root-owned; run as root instead of the
      # image's uid-1000 step user so the 0600 key stays readable.
      user = "0"
      volumes = [
        "/etc/infra/step/ca.json:/home/step/config/ca.json:Z",
        "/etc/infra/step/root_ca.crt:/home/step/certs/root_ca.crt:Z",
        "/etc/infra/step/intermediate_ca.crt:/home/step/certs/intermediate_ca.crt:Z",
        "/etc/infra/step/intermediate_ca_key:/home/step/secrets/intermediate_ca_key:Z",
        "step-db:/home/step/db",
      ]
    },
    {
      name  = "node-exporter"
      image = "quay.io/prometheus/node-exporter:latest"
      ports = ["9100:9100"]
    },
  ]
}

# ---------------------------------------------------------------------------
# Registry VM: pull-through cache for docker.io (the only rate-limited
# upstream the stack uses); service VMs point at it via a registries.conf
# mirror drop-in. This VM itself pulls direct to avoid a bootstrap loop.
# ---------------------------------------------------------------------------
module "registry" {
  source    = "./modules/vm"
  providers = { libvirt = libvirt.vhost }

  name             = "registry-vm"
  pool_name        = libvirt_pool.vhost.name
  base_volume_path = libvirt_volume.base_vhost.path
  vcpu             = 2
  memory_mib       = 2048
  disk_gib         = 40
  bridge           = var.vhost_bridge
  static_ip        = "${local.service_ips.registry}${var.vhost_lan_cidr_suffix}"
  gateway          = var.vhost_gateway
  dns              = local.vm_dns
  firmware         = var.uefi_firmware
  nvram_template   = var.uefi_nvram_template
  vm_user          = var.vm_user
  ssh_public_key   = trimspace(file(pathexpand(var.ssh_public_key_path)))

  extra_files = [
    { path = "/etc/infra/Caddyfile", content = local.caddyfiles.registry },
    { path = "/etc/infra/root_ca.crt", content = local.root_ca_cert_pem },
    local.root_ca_anchor_file,
  ]

  containers = [
    {
      # Not published on the host: TLS-terminated by caddy only.
      name  = "registry"
      image = "docker.io/library/registry:3"
      environment = {
        REGISTRY_PROXY_REMOTEURL = "https://registry-1.docker.io"
      }
      volumes = ["registry-data:/var/lib/registry"]
    },
    {
      name       = "caddy"
      image      = "docker.io/library/caddy:latest"
      ports      = ["80:80", "443:443"]
      depends_on = ["registry"]
      volumes = [
        "/etc/infra/Caddyfile:/etc/caddy/Caddyfile:Z",
        "/etc/infra/root_ca.crt:/etc/caddy/root_ca.crt:Z",
        "caddy-data:/data",
      ]
    },
    {
      name  = "node-exporter"
      image = "quay.io/prometheus/node-exporter:latest"
      ports = ["9100:9100"]
    },
  ]
}
