# ---------------------------------------------------------------------------
# Infra VMs: DNS (CoreDNS, lab.internal zone), CA (step-ca, internal ACME),
# and a docker.io pull-through registry cache.
# ---------------------------------------------------------------------------
locals {
  internal_domain = "lab.internal"

  # A records: every VM by name (dns/ca/registry are first-class entries in
  # service_ips), the two Gitea Actions runner VMs, plus the KVM host itself.
  dns_a_records = merge(local.service_ips, local.gitea_runner_ips, {
    vhost = var.vhost_host
  })

  # CNAMEs for services that share a VM.
  dns_cname_records = {
    grafana    = "monitoring"
    prometheus = "monitoring"
    ntfy       = "monitoring"
    # dns.lab.internal is the stable name clients use for DNS resolution; it's
    # a CNAME to the load balancer (dns-lb) in front of the dns1/dns2 backends.
    dns = "dns-lb"
  }

  # Both CoreDNS VMs serve identical copies of the zone. They are the LB's
  # backends (dns1/dns2); the `dns` name itself now belongs to the LB above.
  dns_vms = {
    dns1 = local.service_ips.dns1
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
  # Each dns VM's Caddyfile serves TWO hostnames: its own <name>.lab.internal
  # (for direct per-VM DoH) AND dns.lab.internal (for the load-balanced DoH
  # endpoint fronted by dns-lb's L4 :443 SNI routing). Both share the same
  # /dns-query reverse_proxy to coredns:8053. caddy issues a single ACME cert
  # covering both names (caddy treats multiple site addresses in one block as
  # one cert with multiple SANs), so the cert presented for
  # https://dns.lab.internal/dns-query is valid for dns.lab.internal -- the
  # SNI the LB forwards. This is what makes L4 TLS passthrough work: the LB
  # doesn't terminate TLS, the backend does, and the backend's cert matches
  # the hostname the client requested.
  dns_caddyfile_per_vm = {
    for name in sort(keys(local.dns_vms)) : name => <<-EOT
      ${name}.${local.internal_domain}, dns.${local.internal_domain} {
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

  # Layer-4 config for the DNS load balancer (dns.lab.internal = .26), as
  # Caddy JSON (the layer4 app has no caddyfile adapter, so the config is
  # written as native JSON -- a hand-written `layer4 { ... }` Caddyfile fails
  # to parse and caddy never starts). THREE layer4 servers:
  #
  # 1. dns-tcp: ":53" (TCP) -> round-robins DNS-over-TCP to the backends.
  # 2. dns-udp: "udp/:53" (UDP) -> round-robins DNS-over-UDP (the common case;
  #    `dig` defaults to UDP). A single ":53" listener with mixed udp//tcp
  #    upstreams is NOT enough: caddy-l4's bare ":53" binds TCP only, so UDP
  #    queries were refused with "connection refused" (the original bug).
  # 3. doh-https: ":443" (TCP) -> TLS SNI matching on "dns.lab.internal",
  #    round-robins raw TCP to the backends' :443 (where each dns VM's caddy
  #    terminates TLS with an ACME cert that includes dns.lab.internal as a
  #    SAN). The LB does NOT terminate TLS -- it forwards the raw TCP stream,
  #    so the TLS handshake (cert, SNI, ALPN) passes through to the backend
  #    unchanged. This gives a single DoH endpoint
  #    (https://dns.lab.internal/dns-query) that load-balances across both
  #    backends, with valid TLS (the cert matches dns.lab.internal via SAN).
  #
  # The stock library/caddy image only terminates HTTP/TCP and ships WITHOUT
  # the layer4 module; this uses a custom caddy build (images/caddy-l4/Dockerfile,
  # xcaddy --with github.com/mholt/caddy-l4) published to
  # ghcr.io/chris-briddock/caddy-l4. No TLS terminates on the LB: :53 is raw
  # plaintext DNS, :443 is raw TCP passthrough to the backends' TLS. There is
  # no ACME/cert step on the LB -- the CA-dependent caddies (the per-VM dns
  # caddies that terminate DoH TLS, registry) are the other VMs, not this one.
  dns_lb_caddyfile = jsonencode({
    apps = {
      layer4 = {
        servers = {
          # TCP listener: answers DNS-over-TCP queries, proxying to the
          # backends' TCP :53.
          dns-tcp = {
            listen = [":53"]
            routes = [{
              handle = [{
                handler = "proxy"
                upstreams = [
                  { dial = ["tcp/${local.service_ips.dns1}:53"] },
                  { dial = ["tcp/${local.service_ips.dns2}:53"] },
                ]
              }]
            }]
          }
          # UDP listener: answers DNS-over-UDP queries (the common case --
          # `dig` defaults to UDP), proxying to the backends' UDP :53.
          dns-udp = {
            listen = ["udp/:53"]
            routes = [{
              handle = [{
                handler = "proxy"
                upstreams = [
                  { dial = ["udp/${local.service_ips.dns1}:53"] },
                  { dial = ["udp/${local.service_ips.dns2}:53"] },
                ]
              }]
            }]
          }
          # DoH listener: forwards raw :443 TCP to the backends' caddies,
          # which terminate TLS with an ACME cert that includes
          # dns.lab.internal as a SAN. The LB matches on TLS SNI
          # (dns.lab.internal) so non-DoH traffic to :443 is not proxied.
          # No TLS termination here -- the TCP stream (including the TLS
          # handshake) passes through to the backend unchanged.
          doh-https = {
            listen = [":443"]
            routes = [{
              match = [{
                tls = {
                  sni = ["dns.${local.internal_domain}"]
                }
              }]
              handle = [{
                handler = "proxy"
                upstreams = [
                  { dial = ["tcp/${local.service_ips.dns1}:443"] },
                  { dial = ["tcp/${local.service_ips.dns2}:443"] },
                ]
              }]
            }]
          }
          # ACME HTTP-01 challenge listener: when caddy on a dns backend
          # requests a cert for dns.lab.internal, step-ca validates by
          # fetching http://dns.lab.internal/.well-known/acme-challenge/TOKEN.
          # Since dns.lab.internal is a CNAME to dns-lb (.26), the LB must
          # forward :80 TCP to the backends' caddy :80 (caddy automatically
          # serves HTTP-01 challenge tokens on :80). Without this, step-ca
          # gets connection refused and the cert never issues. This is L4
          # TCP passthrough -- no HTTP parsing, no TLS.
          acme-http = {
            listen = [":80"]
            routes = [{
              handle = [{
                handler = "proxy"
                upstreams = [
                  { dial = ["tcp/${local.service_ips.dns1}:80"] },
                  { dial = ["tcp/${local.service_ips.dns2}:80"] },
                ]
              }]
            }]
          }
        }
      }
    }
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
    # Registry mirror drop-in: like every other VM, docker.io pulls for the
    # coredns/node-exporter images should go through the lab cache. The dns
    # VMs resolve through var.vhost_dns (public), which can't resolve
    # lab.internal, so the coredns container below carries an --add-host entry
    # pinning registry.lab.internal to the registry VM's IP — without it the
    # mirror drop-in's location is unresolvable and podman falls back to
    # direct docker.io (anonymous, rate-limited; this is what left dns2's
    # coredns thrashing on toomanyrequests when the shared-IP limit ran out).
    local.registry_mirror_file,
  ]

  containers = [
    {
      name  = "coredns"
      image = "docker.io/coredns/coredns:latest"
      # Pin registry.lab.internal in the container's hosts file: the dns VMs
      # resolve through var.vhost_dns (public resolvers) which can't resolve
      # lab.internal, so without this the registry mirror drop-in's location
      # is unresolvable and podman falls back to direct docker.io (anonymous,
      # rate-limited). Same pattern as the caddy --add-host for ca.lab.internal
      # below; the registry VM IP is fixed in service_ips.
      extra_args = ["--add-host", "registry.lab.internal:${local.service_ips.registry}"]
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
# DNS load balancer: dns.lab.internal = .26. A single caddy-l4 container
# round-robins THREE protocols across the two CoreDNS backends (dns1/dns2):
#   - Plaintext DNS (:53, udp+tcp) -> direct to CoreDNS :53 on each backend
#   - DoH (:443) -> L4 TLS passthrough to the per-VM caddies on :443, which
#     terminate TLS with an ACME cert covering dns.lab.internal (SAN) and
#     reverse-proxy /dns-query to coredns:8053
#   - ACME HTTP-01 (:80) -> L4 TCP to the per-VM caddies on :80, where caddy
#     serves challenge tokens. Required because dns.lab.internal CNAMEs to
#     dns-lb, so step-ca connects to the LB's :80 to validate certs for
#     dns.lab.internal. Without this, the ACME challenge stalls and the
#     cert never issues.
# Clients' vm_dns points here (with 1.1.1.1 as a catastrophe fallback), so a
# single backend outage is invisible to the fleet. DoH clients use
# https://dns.lab.internal/dns-query (the LB forwards raw TCP to a backend's
# caddy, which terminates TLS — the LB does NOT terminate TLS for DoH).
#
# This VM must NOT resolve through the internal DNS it fronts: its own boot
# pulls the caddy image before any CoreDNS is up, and the LB would otherwise
# depend on the very service that depends on it. It uses the public upstream
# (vhost_dns) for its own resolution.
#
# DNS needs Layer-4 (udp+tcp for plaintext DNS, TLS passthrough for DoH),
# which the stock library/caddy image cannot do -- it only terminates
# HTTP/TCP. This uses a custom caddy build with the layer4 community module
# (ghcr.io/chris-briddock/caddy-l4:latest, built from
# images/caddy-l4/Dockerfile via xcaddy), driven by a JSON config since
# layer4 has no caddyfile adapter. The image is pulled directly from ghcr.io
# (public registry, resolvable via vhost_dns) so the LB has no dependency on
# the lab registry or internal DNS for its own bootstrap. The LB forwards
# raw TCP for both :53 (plaintext DNS) and :443 (DoH) to the backends; it
# does NOT terminate TLS for either.
# ---------------------------------------------------------------------------
module "dns_lb" {
  source    = "./modules/vm"
  providers = { libvirt = libvirt.vhost }

  name             = "dns-lb-vm"
  pool_name        = libvirt_pool.vhost.name
  base_volume_path = libvirt_volume.base_vhost.path
  vcpu             = 1
  memory_mib       = 512
  disk_gib         = 5
  bridge           = var.vhost_bridge
  static_ip        = "${local.service_ips.dns-lb}${var.vhost_lan_cidr_suffix}"
  gateway          = var.vhost_gateway
  # Resolve through the public upstream, NOT the internal DNS: the backends
  # come up after this VM and the LB can't bootstrap on the service it serves.
  dns            = var.vhost_dns
  firmware       = var.uefi_firmware
  nvram_template = var.uefi_nvram_template
  vm_user        = var.vm_user
  ssh_public_key = trimspace(file(pathexpand(var.ssh_public_key_path)))

  extra_files = [
    { path = "/etc/infra/caddy.json", content = local.dns_lb_caddyfile },
  ]

  containers = [
    {
      name = "caddy"
      # Custom caddy build WITH the layer4 app (images/caddy-l4/Dockerfile,
      # built via xcaddy --with github.com/mholt/caddy-l4), published to
      # ghcr.io/chris-briddock/caddy-l4:latest. The stock official caddy image
      # (library/caddy, ghcr.io/caddyserver/caddy) ships WITHOUT the layer4
      # module and can only do HTTP/TCP termination, not raw UDP/TCP L4
      # forwarding; the unofficial ghcr.io/mholt/caddy-l4 returns 403 Forbidden
      # and is not reliably pullable. So we build from source and publish to
      # ghcr.io. This VM resolves through var.vhost_dns (public), which CAN
      # resolve ghcr.io, so the pull has no dependency on the lab registry or
      # internal DNS -- the LB bootstraps independently of the services it
      # fronts.
      image = "ghcr.io/chris-briddock/caddy-l4:latest"
      # JSON config (no --adapter): layer4 has no caddyfile adapter, and a
      # hand-written `layer4 { }` Caddyfile fails to parse (caddy won't start),
      # so the config is written as native caddy JSON. JSON is caddy's native
      # format, so it is read directly with --config -- NO --adapter flag.
      # The `--adapter` flag is only for converting NON-native formats (e.g.
      # Caddyfile) into JSON; there is no "json" adapter because JSON needs no
      # conversion. A custom xcaddy build (this image) bundles no config
      # adapters at all, so `--adapter json` fails with "unrecognized config
      # adapter: json". The stock library/caddy image includes the caddyfile
      # adapter, which is why an earlier emergency-recovery build tolerated it.
      command = "caddy run --config /etc/caddy/caddy.json"
      # :53 must bind the LAN IP specifically (see the CoreDNS port notes on
      # module.dns) so systemd-resolved's 127.0.0.53:53 stub doesn't clash.
      # :443 is the DoH load-balancer (L4 TLS passthrough to dns1/dns2 caddy).
      # :80 is the ACME HTTP-01 challenge forwarder (L4 TCP to dns1/dns2 :80,
      # where their caddy serves the challenge tokens for dns.lab.internal).
      ports = [
        "${local.service_ips.dns-lb}:53:53",
        "${local.service_ips.dns-lb}:53:53/udp",
        "${local.service_ips.dns-lb}:80:80",
        "${local.service_ips.dns-lb}:443:443",
      ]
      volumes = [
        "/etc/infra/caddy.json:/etc/caddy/caddy.json:Z",
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

  extra_files = concat(
    [
      # Custom Caddyfile with path-routing to the writable + cache instances
      # (NOT the caddyfiles.registry from caddy_sites — that only does a single
      # reverse_proxy to :5000 and can't path-route to the caches).
      { path = "/etc/infra/Caddyfile", content = local.registry_caddyfile },
      { path = "/etc/infra/root_ca.crt", content = local.root_ca_cert_pem },
      # Writable registry config (no proxy block = pushable).
      { path = "/etc/infra/registry/local.yml", content = local.registry_config },
      local.root_ca_anchor_file,
    ],
    # One config file per upstream pull-through cache instance.
    values(local.registry_cache_files),
  )

  containers = [
    {
      # Writable registry instance (:5000). Hosts custom/lab-built images
      # and is pushable. NOT a pull-through cache (no proxy block in the
      # config) — the old REGISTRY_PROXY_REMOTEURL env var made the whole
      # instance read-only (pushes 500'd). Not published on the host:
      # TLS-terminated by caddy only.
      name    = "registry"
      image   = "docker.io/library/registry:3"
      command = "/entrypoint.sh /etc/docker/registry/config.yml"
      volumes = [
        "/etc/infra/registry/local.yml:/etc/docker/registry/config.yml:Z",
        "registry-data:/var/lib/registry",
      ]
    },
    {
      # docker.io pull-through cache (:5001). Fetches+caches from
      # registry-1.docker.io on first request. Read-only (proxy mode).
      name    = "registry-cache-docker"
      image   = "docker.io/library/registry:3"
      command = "/entrypoint.sh /etc/docker/registry/config.yml"
      volumes = [
        "/etc/infra/registry/docker.io.yml:/etc/docker/registry/config.yml:Z",
        "registry-cache-docker:/var/lib/registry",
      ]
    },
    {
      # quay.io pull-through cache (:5002).
      name    = "registry-cache-quay"
      image   = "docker.io/library/registry:3"
      command = "/entrypoint.sh /etc/docker/registry/config.yml"
      volumes = [
        "/etc/infra/registry/quay.io.yml:/etc/docker/registry/config.yml:Z",
        "registry-cache-quay:/var/lib/registry",
      ]
    },
    {
      # ghcr.io pull-through cache (:5003).
      name    = "registry-cache-ghcr"
      image   = "docker.io/library/registry:3"
      command = "/entrypoint.sh /etc/docker/registry/config.yml"
      volumes = [
        "/etc/infra/registry/ghcr.io.yml:/etc/docker/registry/config.yml:Z",
        "registry-cache-ghcr:/var/lib/registry",
      ]
    },
    {
      # mcr.microsoft.com pull-through cache (:5004).
      name    = "registry-cache-mcr"
      image   = "docker.io/library/registry:3"
      command = "/entrypoint.sh /etc/docker/registry/config.yml"
      volumes = [
        "/etc/infra/registry/mcr.microsoft.com.yml:/etc/docker/registry/config.yml:Z",
        "registry-cache-mcr:/var/lib/registry",
      ]
    },
    {
      name       = "caddy"
      image      = "docker.io/library/caddy:latest"
      ports      = ["80:80", "443:443"]
      depends_on = ["registry", "registry-cache-docker", "registry-cache-quay", "registry-cache-ghcr", "registry-cache-mcr"]
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
