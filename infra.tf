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
        forward . ${join(" ", var.vhost_dns)}
        cache 300
        prometheus 0.0.0.0:9153
        log
        errors
    }
  EOT

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
  memory_mib       = 2048
  disk_gib         = 15
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

  extra_files = [
    { path = "/etc/infra/coredns/Corefile", content = local.coredns_corefile },
    { path = "/etc/infra/coredns/${local.internal_domain}.zone", content = local.dns_zone_file },
    { path = "/etc/infra/coredns/${local.dns_reverse_zone_name}.zone", content = local.dns_reverse_zone_file },
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
      volumes = [
        "/etc/infra/coredns/Corefile:/etc/coredns/Corefile:Z",
        "/etc/infra/coredns/${local.internal_domain}.zone:/etc/coredns/${local.internal_domain}.zone:Z",
        "/etc/infra/coredns/${local.dns_reverse_zone_name}.zone:/etc/coredns/${local.dns_reverse_zone_name}.zone:Z",
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
  memory_mib       = 2048
  disk_gib         = 15
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
    { path = "/etc/infra/step/intermediate_ca.crt", content = tls_locally_signed_cert.intermediate.cert_pem },
    {
      path        = "/etc/infra/step/intermediate_ca_key"
      content     = tls_private_key.intermediate.private_key_pem
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
  memory_mib       = 4096
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
