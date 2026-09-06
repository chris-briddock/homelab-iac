locals {
  service_ips = {
    surrealdb  = "192.168.70.10"
    postgres   = "192.168.70.11"
    qvault     = "192.168.70.12"
    penpot     = "192.168.70.13"
    monitoring = "192.168.70.14"
    aspire     = "192.168.70.15"
    # dns1/dns2 are the two CoreDNS backends (were dns/dns2). dns.lab.internal
    # is now the load-balancer in front of them (see infra.tf module dns_lb);
    # the dns1 backend is CNAME'd from the old `dns` name for DoH back-compat.
    dns1      = "192.168.70.16"
    registry  = "192.168.70.17"
    ca        = "192.168.70.18"
    dns2      = "192.168.70.19"
    gitea     = "192.168.70.20"
    verdaccio = "192.168.70.21"
    nfs       = "192.168.70.22"
    redis     = "192.168.70.23"
    # The DNS load balancer (dns.lb / dns-lb VM). dns.lab.internal is a CNAME
    # to it (infra.tf dns_cname_records) so the dns.lab.internal name the rest
    # of the stack references resolves to this IP.
    dns-lb = "192.168.70.26"
    # OpenBao secrets management: openbao-vm (.27) is the main cluster; the
    # transit-seal provider lives on its own dedicated VM (.28) so one guest
    # reboot never takes down two trust anchors. See plans/openbao-deployment.md.
    openbao         = "192.168.70.27"
    openbao-transit = "192.168.70.28"
  }

  # Gitea Actions runner executor VMs. Nested in service_ips would force
  # every consumer (DNS A-records, caddyfiles, prometheus config, vhost
  # client lists) to handle a mixed scalar/map type, so these live in a
  # separate map; dns_a_records in infra.tf merges both.
  gitea_runner_ips = {
    gitea-runner-1 = "192.168.70.24"
    gitea-runner-2 = "192.168.70.25"
  }

  # Shared by penpot-backend (enforcement) and penpot-frontend (UI rendering
  # of the register/login forms) -- both containers must see the same flags.
  # No SMTP is configured, so email verification must stay off for
  # self-registration to complete.
  penpot_flags = "enable-registration enable-login-with-password disable-email-verification"

  # Caching mirrors baked into the daemon-based Gitea runners (module
  # gitea_runner below). Docker-hub pulls by CI jobs go through the
  # registry VM's pull-through cache; apk/apt fetch through the vm/cache
  # apt-cacher-ng on the vhost. Job containers do NOT share the host's
  # cloud-init config (each job gets a fresh container), so these have to
  # live in the runner daemon's own config file.
  runner_registry_mirrors = ["https://registry.${local.internal_domain}"]
  runner_apt_proxy        = "http://192.168.70.1:3142"

  # Per-VM act_runner config. cache.host_workdir_parent is REQUIRED in daemon
  # mode: the runner creates a per-job workdir under it on the VM and
  # bind-mounts the SAME host path into every job container, so the job sees
  # a consistent checkout path. (Without it, docker.ValidVolumes would have
  # to whitelist an ever-changing tmpdir.)
  act_runner_config = {
    for name, ip in local.gitea_runner_ips : name => yamlencode({
      log = { level = "info" }
      runner = {
        file           = ".runner"
        capacity       = 4
        timeout        = "3h"
        insecure       = false
        fetch_timeout  = "10s"
        fetch_interval = "2s"
        # ubuntu-latest resolves to the node image below; default is empty
        # (jobs must then pin container.image explicitly).
        labels = [
          "ubuntu-latest:docker://docker.io/library/node:24",
          "ubuntu-24.04:docker://docker.io/library/node:24",
        ]
      }
      cache = {
        enabled             = true
        dir                 = "/data/cache"
        host_workdir_parent = "/data/workdirs"
      }
      container = {
        # Total isolation: no socket/exec forwarding from job containers to
        # the daemon. Jobs that need docker-in-docker won't work -- use a
        # service container with the dind image instead.
        privileged = false
        # Bind the lab CA bundle (root + intermediate, written by cloud-init
        # on the runner VM) into every job container read-only. Job images
        # (e.g. node:24 for actions/checkout) trust only public CAs by
        # default, so `git fetch https://gitea.lab.internal/...` failed with
        # "certificate signed by unknown authority". The *_CAINFO /
        # *_CA_CERTS env vars below point each runtime at this file.
        # ":Z" is required on SELinux hosts: without it podman mounts the
        # host file with a label the container can't read and git's libcurl
        # fails with "Problem with the SSL CA cert (path? access rights?)".
        options        = "-v /var/lib/act_runner/ca/lab-ca-bundle.crt:/etc/ssl/certs/lab-ca-bundle.crt:ro,Z"
        workdir_parent = null
        valid_volumes  = []
        docker_host    = "-"
        force_pull     = true
        # Job containers run on the runner's default podman network. A
        # dedicated runnernet was dropped: the act_runner container is
        # ROOTFUL (needed for the podman.sock Docker API) while the vm
        # module's quadlet .network files create ROOTLESS networks for the
        # unprivileged user -- rootful podman cannot see them, so any
        # explicit --network <name> fails with "network not found".
        # Blank string = let the daemon inherit, which lands jobs on the
        # same rootful bridge the runner itself uses.
        network_mode = ""
        # Overrides the built-in gitea/runner-images default. The registry
        # mirror's CA + an apt proxy are baked in so pull/build inside CI
        # jobs works without per-repo hacking. The *_CAINFO / *_CAINFO_BUNDLE
        # vars make the common TLS clients in job containers (git's libcurl,
        # Node's boringssl, curl, python-requests, Go) trust the lab root +
        # intermediate CA mounted at the path in `options` above.
        envs = {
          DOCKER_REGISTRY_MIRRORS = join(",", local.runner_registry_mirrors)
          # Insecure-registries: job-local dockerd (dind service containers)
          # can't be pushed config files, so allow-plainhttp to the lab's
          # own CAs-covered HTTPS cache stays permissive at the daemon level.
          DOCKER_INSECURE_REGISTRIES = "192.168.70.0/22"
          APT_PROXY                  = local.runner_apt_proxy
          # git (libcurl backend) -- used by actions/checkout's `git fetch`.
          GIT_SSL_CAINFO = "/etc/ssl/certs/lab-ca-bundle.crt"
          # Node.js TLS (actions themselves run on node; checkout.js, etc).
          NODE_EXTRA_CA_CERTS = "/etc/ssl/certs/lab-ca-bundle.crt"
          # curl CLI + python-requests, for ad-hoc HTTPS in job steps.
          CURL_CA_BUNDLE     = "/etc/ssl/certs/lab-ca-bundle.crt"
          REQUESTS_CA_BUNDLE = "/etc/ssl/certs/lab-ca-bundle.crt"
          # Go-based tools built inside jobs default to the system store;
          # SSL_CERT_FILE overrides it (Go prefers this over the OS path).
          SSL_CERT_FILE = "/etc/ssl/certs/lab-ca-bundle.crt"
        }
      }
      host = { workdir_parent = null }
    })
  }

  # Service VMs resolve through the DNS load balancer (dns.lab.internal =
  # 192.168.70.26, round-robins the two CoreDNS backends) with 1.1.1.1 as a
  # catastrophe fallback for when the whole internal DNS stack is down.
  #
  # The public fallback is NOT just another nameserver: systemd-resolved would
  # treat equally-weighted per-link servers as interchangeable and sometimes
  # accept a public NXDOMAIN for lab.internal as final. The network-config
  # template writes all of vm_dns into netplan (it can't express split-DNS),
  # and the resolved drop-in in user-data.yaml.tmpl re-marks 1.1.1.1 as a
  # low-priority catch-all (~.) so it's only queried for names the internal
  # LB doesn't claim.
  vm_dns = [local.service_ips.dns-lb, "1.1.1.1"]

  # The PKI is file-based now (see pki.tf): scripts/gen-pki.sh minted the
  # root + intermediate CA as local files, with private keys git-ignored and
  # kept off tfstate entirely. The root cert is public and committed, so the
  # trust anchor is a plain file read. (pki/root-ca-cert.pem is the DEAD
  # previous root -- key lost with a prior tfstate; reference only.)
  root_ca_cert_pem = file("${path.module}/pki/root-ca.crt")

  # Caddyfiles for the per-VM reverse proxies, keyed by VM. Certs come from
  # step-ca on the infra VM via ACME; acme_ca_root trusts its TLS endpoint.
  caddy_sites = {
    qvault = { qvault = "qvault:3000" }
    penpot = { penpot = "penpot-frontend:8080" }
    # ntfy is fronted by caddy so the phone app can subscribe over HTTPS with
    # the step-ca cert (the LAN already trusts the lab root CA).
    monitoring = { grafana = "grafana:3000", prometheus = "prometheus:9090", ntfy = "ntfy:80" }
    aspire     = { aspire = "aspire-dashboard:18888" }
    # registry is NOT here: it has a custom Caddyfile (registry_caddyfile)
    # with path-routing to multiple backend instances (writable + 4 caches).
    gitea     = { gitea = "gitea:3000" }
    verdaccio = { verdaccio = "verdaccio:4873" }
    # OpenBao main cluster: caddy terminates openbao.lab.internal and proxies
    # to the openbao container's API on :8200 (plaintext inside vmnet; TLS at
    # the edge, same as every other service).
    openbao = { openbao = "openbao:8200" }
  }

  # The tls issuer must be set explicitly per site: Caddy classifies
  # *.internal (and *.home.arpa) names as internal-only and silently uses its
  # own local CA instead of ACME when only the global acme_ca option is set.
  caddyfiles = {
    for vm, sites in local.caddy_sites : vm => join("\n\n", [
      for host, upstream in sites : <<-EOT
        ${host}.${local.internal_domain} {
            reverse_proxy ${upstream}
            tls {
                issuer acme {
                    dir https://ca.${local.internal_domain}:9000/acme/acme/directory
                    trusted_roots /etc/caddy/root_ca.crt
                }
            }
        }
      EOT
    ])
  }

  # registry-vm builds its own extra_files (it must not get the mirror
  # drop-in pointing at itself).
  caddy_extra_files = {
    for vm in keys(local.caddy_sites) : vm => [
      { path = "/etc/infra/Caddyfile", content = local.caddyfiles[vm] },
      { path = "/etc/infra/root_ca.crt", content = local.root_ca_cert_pem },
      local.root_ca_anchor_file,
      local.registry_mirror_file,
    ] if vm != "registry"
  }

  # Root CA into the OS trust store (activated by update-ca-trust in runcmd);
  # podman validates the HTTPS registry mirror against the system trust.
  root_ca_anchor_file = {
    path    = "/etc/pki/ca-trust/source/anchors/lab-internal-root-ca.crt"
    content = local.root_ca_cert_pem
  }

  # Intermediate CA cert, written to the VM for containers that must trust the
  # step-ca-issued leaf certs (gitea's Caddy presents a cert signed by this
  # intermediate; the root anchor alone is sufficient for OS-level validation
  # because the root signs the intermediate, but shipping the intermediate too
  # lets container images without a root-only bundle path validate directly).
  intermediate_ca_cert_pem = file("${path.module}/pki/intermediate-ca.crt")

  # Combined root + intermediate bundle. CI job containers (node:24 etc.) are
  # pointed at this single file via GIT_SSL_CAINFO / NODE_EXTRA_CA_CERTS /
  # *_CA_BUNDLE; a one-file bundle works for every TLS client without needing
  # each image's update-ca-certificates (several of which don't ship it).
  lab_ca_bundle_pem = "${local.root_ca_cert_pem}\n${local.intermediate_ca_cert_pem}"

  # All four upstream registries the fleet uses are mirrored through the
  # registry VM's pull-through caches (TLS via its Caddy). podman falls back
  # to the upstream directly if a mirror is unreachable. Sharing one client
  # identity (the registry VM) across the fleet avoids per-VM anonymous
  # rate-limits (which took dns2's coredns down on 2026-09-01). The mirror
  # paths match the Caddyfile path-routing in registry_caddyfile below.
  registry_mirror_file = {
    path    = "/etc/containers/registries.conf.d/50-registry-mirrors.conf"
    content = <<-EOT
      [[registry]]
      prefix = "docker.io"
      location = "docker.io"

      [[registry.mirror]]
      location = "registry.${local.internal_domain}/docker.io"

      [[registry]]
      prefix = "quay.io"
      location = "quay.io"

      [[registry.mirror]]
      location = "registry.${local.internal_domain}/quay.io"

      [[registry]]
      prefix = "ghcr.io"
      location = "ghcr.io"

      [[registry.mirror]]
      location = "registry.${local.internal_domain}/ghcr.io"

      [[registry]]
      prefix = "mcr.microsoft.com"
      location = "mcr.microsoft.com"

      [[registry.mirror]]
      location = "registry.${local.internal_domain}/mcr.microsoft.com"
    EOT
  }

  # Distribution registry config for the WRITABLE instance (:5000). This hosts
  # custom/lab-built images and is pushable. No `proxy` block = not a cache.
  # delete.enabled=true so stale custom tags can be pruned.
  registry_config = <<-YAML
    version: 0.1
    log:
      level: info
    storage:
      cache:
        blobdescriptor: inmemory
      filesystem:
        rootdirectory: /var/lib/registry/local
      delete:
        enabled: true
    http:
      addr: :5000
      headers:
        X-Content-Type-Options: [nosniff]
  YAML

  # Pull-through cache configs: one distribution instance per upstream, each on
  # its own port with its own storage subdir. The `proxy.remoteurl` block is
  # what turns a plain registry into a pull-through cache for that single
  # upstream (and makes it read-only — which is why pushes go to :5000 above,
  # not to a cache instance). delete.enabled=false on caches (a mirror, not a
  # store).
  registry_cache_configs = {
    "docker.io"         = { port = 5001, url = "https://registry-1.docker.io" }
    "quay.io"           = { port = 5002, url = "https://quay.io" }
    "ghcr.io"           = { port = 5003, url = "https://ghcr.io" }
    "mcr.microsoft.com" = { port = 5004, url = "https://mcr.microsoft.com" }
  }

  registry_cache_files = {
    for name, cfg in local.registry_cache_configs : name => {
      path    = "/etc/infra/registry/${name}.yml"
      content = <<-YAML
        version: 0.1
        log:
          level: info
        storage:
          cache:
            blobdescriptor: inmemory
          filesystem:
            rootdirectory: /var/lib/registry/${name}
          delete:
            enabled: false
        http:
          addr: :${cfg.port}
          headers:
            X-Content-Type-Options: [nosniff]
        proxy:
          remoteurl: ${cfg.url}
      YAML
    }
  }

  # Custom Caddyfile for the registry VM. Unlike the other caddy-fronted VMs
  # (which use caddy_sites -> a single reverse_proxy), the registry needs
  # PATH-based routing: /docker.io/* -> :5001, /quay.io/* -> :5002, etc., and
  # everything else (custom images) -> :5000. The path prefix is stripped
  # before proxying so the cache instance sees the normal /v2/<repo> path. TLS
  # via step-ca ACME, same as every other caddy VM.
  registry_caddyfile = <<-EOT
    registry.${local.internal_domain} {
        handle_path /docker.io/* {
            reverse_proxy registry-cache-docker:5001
        }
        handle_path /quay.io/* {
            reverse_proxy registry-cache-quay:5002
        }
        handle_path /ghcr.io/* {
            reverse_proxy registry-cache-ghcr:5003
        }
        handle_path /mcr.microsoft.com/* {
            reverse_proxy registry-cache-mcr:5004
        }
        handle {
            reverse_proxy registry:5000
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

# ---------------------------------------------------------------------------
# OpenBao secrets management (plans/openbao-deployment.md)
# ---------------------------------------------------------------------------
locals {
  # Main OpenBao server config (openbao-vm, .27). Single-node Raft integrated
  # storage on the openbao-data named volume (data dir /openbao — OpenBao's
  # image layout, NOT /vault). TLS is terminated by caddy on :443, so the
  # listener is plaintext :8200 inside the podman vmnet network (same edge-TLS
  # pattern as every other service). Auto-unseal via a transit seal pointing at
  # the dedicated openbao-transit-vm (.28). The transit token is substituted
  # from a root-only file delivered out-of-band (NEVER via tofu/extra_files —
  # it would land in tfstate); the __TRANSIT_TOKEN__ placeholder is replaced by
  # a tiny config-render step before the openbao service starts.
  openbao_config = <<-EOT
    ui           = true
    api_addr     = "https://openbao.${local.internal_domain}"
    cluster_addr = "https://${local.service_ips.openbao}:8201"

    listener "tcp" {
      address     = "0.0.0.0:8200"
      tls_disable = true
    }

    storage "raft" {
      # Raft storage path = the mount root of the openbao-data volume
      # (openbao-data:/openbao). Using the root (image-owned, exists, writable)
      # avoids the "failed to create fsm / open <path>/vault.db: no such file
      # or directory" crash that occurs when pointing at a non-existent subdir
      # that bolt/raft will not create inside the mount.
      path    = "/openbao"
      node_id = "openbao-1"
    }

    # NOTE: this is the DEFAULT (Shamir) config. A `seal` block is deliberately
    # absent so the main openbao always starts cleanly on its own:
    #   - no `seal` block  => Shamir seal. `bao operator init` + `bao operator
    #     unseal` (the operator's recovery keys) get it serving.
    #   - transit auto-unseal is an OPTIONAL operator overlay: to enable it,
    #     paste the seal "transit" { ... } block (with the real transit token,
    #     which is delivered out-of-band and never stored in tofu/extra_files)
    #     here on the VM at /etc/infra/openbao/openbao.hcl only, then run
    #     `bao operator migrate`, then restart. Keeping it out of the default
    #     config avoids the init/auto-unseal chicken-and-egg AND keeps the
    #     transit token out of the templating path entirely. See the runbook
    #     in plans/openbao-deployment.md §6.
  EOT

  # Transit-seal provider config (openbao-transit-vm, .28). Shamir-sealed (no
  # `seal` block = Shamir); the operator unseals it manually after a transit-vm
  # reboot (the documented root-of-trust bottom). LAN-internal only — no caddy
  # in front; the main openbao reaches it directly on :8200.
  transit_config = <<-EOT
    ui           = false
    api_addr     = "http://${local.service_ips.openbao-transit}:8200"
    cluster_addr = "https://${local.service_ips.openbao-transit}:8201"

    listener "tcp" {
      address     = "0.0.0.0:8200"
      tls_disable = true
    }

    storage "raft" {
      # Same fix as the main cluster: mount root of transit-data:/openbao.
      path    = "/openbao"
      node_id = "openbao-transit-1"
    }
  EOT
}

# 0.9.x: libvirt pools cannot be updated in-place — any change forces
# replacement, which would destroy the pool and all volumes in it.  This
# pool was imported from the already-running libvirt, so ignore all
# post-import drift (auto-populated allocation/available, target path
# already correct on the host).
resource "libvirt_pool" "vhost" {
  provider = libvirt.vhost
  name     = var.pool_name
  type     = "dir"

  target = {
    path = var.pool_path
  }

  lifecycle {
    ignore_changes = all
  }
}

# 0.9.x: top-level source/format replaced by target.format + create.content.url.
# 0.9.x volumes cannot be updated in-place; this base image was imported
# from the running vhost, so ignore all post-import drift (auto-populated
# allocation/physical, target permissions/timestamps, and the `create`
# upload directive which is absent from state after import).
resource "libvirt_volume" "base_vhost" {
  provider = libvirt.vhost
  name     = "fedora-cloud-base.qcow2"
  pool     = libvirt_pool.vhost.name

  target = {
    format = {
      type = "qcow2"
    }
  }

  create = {
    content = {
      url = var.base_image_url
    }
  }

  lifecycle {
    ignore_changes = all
  }
}

# ---------------------------------------------------------------------------
# SurrealDB
# ---------------------------------------------------------------------------
module "surrealdb" {
  source    = "./modules/vm"
  providers = { libvirt = libvirt.vhost }

  name             = "surrealdb-vm"
  pool_name        = libvirt_pool.vhost.name
  base_volume_path = libvirt_volume.base_vhost.path
  vcpu             = 4
  memory_mib       = 4096
  disk_gib         = 15
  bridge           = var.vhost_bridge
  static_ip        = "${local.service_ips.surrealdb}${var.vhost_lan_cidr_suffix}"
  gateway          = var.vhost_gateway
  dns              = local.vm_dns
  firmware         = var.uefi_firmware
  nvram_template   = var.uefi_nvram_template
  vm_user          = var.vm_user
  ssh_public_key   = trimspace(file(pathexpand(var.ssh_public_key_path)))

  extra_files = [local.registry_mirror_file, local.root_ca_anchor_file]

  containers = [
    {
      name    = "surrealdb"
      image   = "docker.io/surrealdb/surrealdb:v2"
      command = "start"
      ports   = ["8000:8000"]
      # surreal's `start` process exits on stdin EOF unless stdin is kept open.
      extra_args = ["-i"]
      # Image runs as UID 65532 by default, which can't write to the
      # root-owned named volume; run as root to avoid a silent rocksdb
      # permission failure.
      user = "0"
      environment = {
        SURREAL_USER = local.secret_usernames.surrealdb_root_password
        SURREAL_PASS = local.secrets_values.surrealdb_root_password
        SURREAL_PATH = "rocksdb:/data/database.db"
        SURREAL_BIND = "0.0.0.0:8000"
      }
      volumes = ["surrealdb-data:/data"]
    },
    {
      name  = "node-exporter"
      image = "quay.io/prometheus/node-exporter:latest"
      ports = ["9100:9100"]
    },
  ]
}

# ---------------------------------------------------------------------------
# Standalone Postgres
# ---------------------------------------------------------------------------
module "postgres" {
  source    = "./modules/vm"
  providers = { libvirt = libvirt.vhost }

  name             = "postgres-vm"
  pool_name        = libvirt_pool.vhost.name
  base_volume_path = libvirt_volume.base_vhost.path
  vcpu             = 4
  memory_mib       = 4096
  disk_gib         = 20
  bridge           = var.vhost_bridge
  static_ip        = "${local.service_ips.postgres}${var.vhost_lan_cidr_suffix}"
  gateway          = var.vhost_gateway
  dns              = local.vm_dns
  firmware         = var.uefi_firmware
  nvram_template   = var.uefi_nvram_template
  vm_user          = var.vm_user
  ssh_public_key   = trimspace(file(pathexpand(var.ssh_public_key_path)))

  extra_files = [local.registry_mirror_file, local.root_ca_anchor_file]

  # Create the tofu state backend (tofu_state DB + tofu role) on first boot.
  # The tofu role has a DEDICATED password (tofu_state_password in OpenBao) that
  # is SEPARATE from the postgres superuser password — PG_CONN_STR uses this
  # role+password, never the superuser. The runcmd runs as the superuser
  # (postgres_password) to provision the role+db. Idempotent.
  extra_runcmd = [
    ["bash", "-c", "until podman exec postgres psql -U ${local.secret_usernames.postgres_password} -c 'SELECT 1' >/dev/null 2>&1; do sleep 2; done; podman exec postgres psql -U ${local.secret_usernames.postgres_password} -v ON_ERROR_STOP=1 -c \"CREATE ROLE tofu LOGIN PASSWORD '${local.secrets_values.tofu_state_password}'\" || podman exec postgres psql -U ${local.secret_usernames.postgres_password} -v ON_ERROR_STOP=1 -c \"ALTER ROLE tofu WITH LOGIN PASSWORD '${local.secrets_values.tofu_state_password}'\"; podman exec postgres psql -U ${local.secret_usernames.postgres_password} -v ON_ERROR_STOP=1 -c 'CREATE DATABASE tofu_state OWNER tofu' || true; podman exec postgres psql -U ${local.secret_usernames.postgres_password} -v ON_ERROR_STOP=1 -c 'GRANT ALL ON DATABASE tofu_state TO tofu'"],
  ]

  containers = [
    {
      name  = "postgres"
      image = "docker.io/library/postgres:16"
      ports = ["5432:5432"]
      environment = {
        POSTGRES_USER     = local.secret_usernames.postgres_password
        POSTGRES_PASSWORD = local.secrets_values.postgres_password
      }
      volumes = ["postgres-data:/var/lib/postgresql/data"]
    },
    {
      name       = "postgres-exporter"
      image      = "quay.io/prometheuscommunity/postgres-exporter:latest"
      ports      = ["9187:9187"]
      depends_on = ["postgres"]
      environment = {
        DATA_SOURCE_NAME = "postgresql://${local.secret_usernames.postgres_password}:${local.secrets_values.postgres_password}@postgres:5432/postgres?sslmode=disable"
      }
    },
    {
      name  = "node-exporter"
      image = "quay.io/prometheus/node-exporter:latest"
      ports = ["9100:9100"]
    },
  ]
}

# ---------------------------------------------------------------------------
# Redis: shared cache for lab services. TLS-only: the plaintext listener is
# disabled (`port 0`) and 6379 speaks TLS with a self-signed cert minted at
# first boot (same pattern as the CoreDNS DoH listener in infra.tf -- no
# tofu-readable CA key exists to sign with, so clients either pin this cert
# as their CA bundle or skip verification on the private LAN). AUTH via a
# random password is still required on top of TLS.
# ---------------------------------------------------------------------------
locals {
  redis_conf = <<-EOT
    # No plaintext listener: TLS is the only way in.
    port 0
    tls-port 6379
    bind 0.0.0.0
    protected-mode yes

    tls-cert-file /etc/redis/tls/redis.crt
    tls-key-file /etc/redis/tls/redis.key
    # Clients authenticate by password, not client certs.
    tls-auth-clients no

    requirepass ${local.secrets_values.redis_password}

    # Treat this as a cache, not a store: bounded memory, LRU eviction, and
    # no persistence -- losing the dataset on rebuild is by design.
    maxmemory 512mb
    maxmemory-policy allkeys-lru
    appendonly no
    save ""
  EOT
}

module "redis" {
  source    = "./modules/vm"
  providers = { libvirt = libvirt.vhost }

  name             = "redis-vm"
  pool_name        = libvirt_pool.vhost.name
  base_volume_path = libvirt_volume.base_vhost.path
  vcpu             = 2
  memory_mib       = 1024
  disk_gib         = 5
  bridge           = var.vhost_bridge
  static_ip        = "${local.service_ips.redis}${var.vhost_lan_cidr_suffix}"
  gateway          = var.vhost_gateway
  dns              = local.vm_dns
  firmware         = var.uefi_firmware
  nvram_template   = var.uefi_nvram_template
  vm_user          = var.vm_user
  ssh_public_key   = trimspace(file(pathexpand(var.ssh_public_key_path)))

  extra_files = [
    { path = "/etc/infra/redis/redis.conf", content = local.redis_conf },
    local.registry_mirror_file,
    local.root_ca_anchor_file,
  ]

  # Self-signed server cert, minted once at first boot. Mode 0644 on the key
  # because the redis container runs as the unprivileged redis uid; the cert
  # is a LAN-internal encryption hop, not the trust boundary (AUTH is).
  extra_runcmd = [
    ["mkdir", "-p", "/etc/infra/redis/tls"],
    ["openssl", "req", "-x509", "-nodes", "-newkey", "rsa:2048",
      "-keyout", "/etc/infra/redis/tls/redis.key",
      "-out", "/etc/infra/redis/tls/redis.crt",
      "-days", "3650",
      "-subj", "/CN=redis.${local.internal_domain}",
    "-addext", "subjectAltName=DNS:redis.${local.internal_domain},IP:${local.service_ips.redis}"],
    ["chmod", "644", "/etc/infra/redis/tls/redis.key", "/etc/infra/redis/tls/redis.crt"],
  ]

  containers = [
    {
      name    = "redis"
      image   = "docker.io/library/redis:7"
      ports   = ["6379:6379"]
      command = "redis-server /etc/redis/redis.conf"
      volumes = [
        "/etc/infra/redis/redis.conf:/etc/redis/redis.conf:Z",
        "/etc/infra/redis/tls:/etc/redis/tls:Z",
      ]
    },
    {
      name       = "redis-exporter"
      image      = "quay.io/oliver006/redis_exporter:latest"
      ports      = ["9121:9121"]
      depends_on = ["redis"]
      # rediss:// = TLS to the sibling container over the podman network;
      # the server cert is self-signed so verification is skipped. The
      # exporter reads REDIS_PASSWORD straight from the environment.
      command = "--redis.addr=rediss://redis:6379 --skip-tls-verification"
      environment = {
        REDIS_PASSWORD = local.secrets_values.redis_password
      }
    },
    {
      name  = "node-exporter"
      image = "quay.io/prometheus/node-exporter:latest"
      ports = ["9100:9100"]
    },
  ]
}

# ---------------------------------------------------------------------------
# Gitea Actions runners: two isolated executor VMs, each running an
# act_runner daemon that polls https://gitea.lab.internal for jobs and
# executes them in per-job podman containers. The registration token is NOT
# generated here (it's minted by Gitea in the admin UI and passed out-of-band
# via TF_VAR_gitea_runner_registration_token -- see variables.tf).
#
# The podman.socket is exposed to the act_runner container on a dedicated
# bridge network so the daemon can spawn sibling job containers on the VM;
# jobs themselves are started on the same spawned-from-daemon layer and are
# therefore structurally isolated from the runner daemon. Rootless podman
# (used by all other services) is NOT usable here: act_runner speaks the
# Docker API and needs the syscall/interprocess freedom rootful gives it.
# ---------------------------------------------------------------------------
module "gitea_runner" {
  source    = "./modules/vm"
  providers = { libvirt = libvirt.vhost }

  for_each = local.gitea_runner_ips

  name             = "${each.key}-vm"
  pool_name        = libvirt_pool.vhost.name
  base_volume_path = libvirt_volume.base_vhost.path
  vcpu             = 20
  memory_mib       = 4096
  disk_gib         = 20
  bridge           = var.vhost_bridge
  static_ip        = "${each.value}${var.vhost_lan_cidr_suffix}"
  gateway          = var.vhost_gateway
  dns              = local.vm_dns
  firmware         = var.uefi_firmware
  nvram_template   = var.uefi_nvram_template
  vm_user          = var.vm_user
  ssh_public_key   = trimspace(file(pathexpand(var.ssh_public_key_path)))

  extra_files = [
    { path = "/etc/infra/act_runner/config.yaml", content = local.act_runner_config[each.key] },
    local.registry_mirror_file,
    local.root_ca_anchor_file,
    # Combined root+intermediate bundle at the host path bind-mounted into
    # every CI job container (see local.act_runner_config container.options).
    { path = "/var/lib/act_runner/ca/lab-ca-bundle.crt", content = local.lab_ca_bundle_pem },
    # Intermediate CA written next to the root anchor so the act-runner
    # container can mount both into its Debian-style CA directory. Gitea's
    # Caddy presents a leaf cert signed by this intermediate; act_runner
    # (Go) needs the chain in its trust bundle to verify it.
    {
      path    = "/etc/infra/ca/lab-internal-intermediate-ca.crt"
      content = local.intermediate_ca_cert_pem
    },
  ]

  # Rootful podman.socket provides the Docker API act_runner uses to spawn
  # job containers. The quadlets themselves are generated per-container by
  # cloud-init (vm module) as rootless -- that is podman's default unit
  # target. The socket unit is the only rootful moving part.
  extra_runcmd = [
    ["systemctl", "enable", "--now", "podman.socket"],
    # act_runner spawns jobs by bind-mounting a workdir from the *host*
    # (see container.options); pre-create it with _netdev-less tmpfs-free
    # perms so a fresh VM has a stable parent for job containers.
    ["mkdir", "-p", "/var/lib/act_runner/workdirs", "/var/lib/act_runner/cache", "/var/lib/act_runner/ca"],
  ]

  containers = [
    {
      name = "act-runner"
      # Pinned x.y.z tag -- gitea/act_runner publishes only x.y.z + latest on
      # Docker Hub (there is no floating "0.2" major tag; pulling it 404s
      # with manifest unknown). Version must satisfy the Gitea server's
      # minimum runner version (Gitea 1.x requires act_runner >= 0.2.x).
      image = "docker.io/gitea/act_runner:3.3.2"
      # The gitea/act_runner image's ENTRYPOINT is `/sbin/tini -- run.sh`,
      # and run.sh ignores any CMD/Exec= args (it runs `act_runner daemon`
      # directly). To run a custom startup script we MUST override the
      # entrypoint to `sh`; the command below then runs as `sh -c '...'`.
      # Without this override the `cat`/`register` half of the command was
      # silently skipped and the daemon ran with no CA bundle, failing with
      # "tls: failed to verify certificate: x509: certificate signed by
      # unknown authority".
      entrypoint = "sh"
      # Registration happens once against the local .runner state file on
      # the named volume; re-running `register` on an existing file is a
      # no-op (the runner just validates and proceeds to `daemon`).
      # The gitea/act_runner image ships no update-ca-certificates (it's a
      # distroless-ish Alpine build), so the bundle isn't rebuilt by a trust
      # tool. Instead the command concatenates the image's existing public
      # CA bundle with the two lab certs mounted below into a single file,
      # and SSL_CERT_FILE points Go's crypto/x509 pool at it (Go reads
      # SSL_CERT_FILE in preference to the OS default). This was verified
      # working: with the lab root+intermediate appended, `act_runner
      # register` reports "Successfully pinged the Gitea instance server"
      # + "Runner registered successfully". Without it the error was
      # "tls: failed to verify certificate: x509: certificate signed by
      # unknown authority".
      command = "-c 'cat /etc/ssl/certs/ca-certificates.crt /usr/local/share/ca-certificates/lab-internal-root-ca.crt /usr/local/share/ca-certificates/lab-internal-intermediate-ca.crt > /tmp/lab-ca-bundle.crt; act_runner register --no-interactive --instance https://gitea.${local.internal_domain} --token ${var.gitea_runner_registration_token} --name ${each.key} --labels ubuntu-latest:docker://docker.io/library/node:24 --config /etc/act_runner/config.yaml || true; exec act_runner daemon --config /etc/act_runner/config.yaml'"
      environment = {
        CONFIG_FILE   = "/etc/act_runner/config.yaml"
        SSL_CERT_FILE = "/tmp/lab-ca-bundle.crt"
      }
      volumes = [
        "/etc/infra/act_runner/config.yaml:/etc/act_runner/config.yaml:Z",
        # Job containers bind-mount these host paths (the podman socket is
        # rootful, so path translation from the container's /data to the
        # host happens one level up in act_runner's DOCKER_HOST client).
        "/var/lib/act_runner/workdirs:/data/workdirs:Z",
        "/var/lib/act_runner/cache:/data/cache:Z",
        "act-runner-data:/data",
        # Lab root + intermediate CAs into the container; the command above
        # concatenates them with the image's public CA bundle into
        # /tmp/lab-ca-bundle.crt (the image has no update-ca-certificates).
        "/etc/pki/ca-trust/source/anchors/lab-internal-root-ca.crt:/usr/local/share/ca-certificates/lab-internal-root-ca.crt:Z",
        "/etc/infra/ca/lab-internal-intermediate-ca.crt:/usr/local/share/ca-certificates/lab-internal-intermediate-ca.crt:Z",
      ]
      # Rootful podman's Docker-compatible socket; act_runner speaks the
      # Docker API and this lets it spawn sibling job containers on the VM.
      # --privileged + the socket are the documented act_runner pattern:
      # without the socket the daemon has nothing to run jobs on; without
      # --privileged job containers that run apt/apk (CAP_NET_ADMIN,
      # setcap) abort. No --network override (see network_mode note in
      # local.act_runner_config): the container stays on the generated
      # quadlet's Network=... which is fine since the daemon is rootful
      # and rootful podman owns its own network namespace list.
      extra_args = [
        "-v /run/podman/podman.sock:/var/run/docker.sock:Z",
        "--privileged",
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
# qvault
# ---------------------------------------------------------------------------
module "qvault" {
  source    = "./modules/vm"
  providers = { libvirt = libvirt.vhost }

  name             = "qvault-vm"
  pool_name        = libvirt_pool.vhost.name
  base_volume_path = libvirt_volume.base_vhost.path
  vcpu             = 4
  memory_mib       = 2048
  disk_gib         = 5
  bridge           = var.vhost_bridge
  static_ip        = "${local.service_ips.qvault}${var.vhost_lan_cidr_suffix}"
  gateway          = var.vhost_gateway
  dns              = local.vm_dns
  firmware         = var.uefi_firmware
  nvram_template   = var.uefi_nvram_template
  vm_user          = var.vm_user
  ssh_public_key   = trimspace(file(pathexpand(var.ssh_public_key_path)))

  extra_files = local.caddy_extra_files.qvault

  containers = [
    {
      name  = "qvault"
      image = "ghcr.io/chris-briddock/qvault:v1.1.1"
      ports = ["3000:3000"]
      environment = {
        SURREALDB_URL        = "ws://${local.service_ips.surrealdb}:8000/rpc"
        SURREALDB_NS         = "qvault"
        SURREALDB_DB         = "qvault"
        SURREALDB_USER       = local.secret_usernames.surrealdb_root_password
        SURREALDB_PASS       = local.secrets_values.surrealdb_root_password
        SESSION_SECRET       = local.secrets_values.qvault_session_secret
        SERVER_SECRET        = local.secrets_values.qvault_server_secret
        WEBAUTHN_RP_NAME     = "QVault"
        WEBAUTHN_RP_ID       = "qvault.${local.internal_domain}"
        WEBAUTHN_ORIGIN      = "https://qvault.${local.internal_domain}"
        NEXT_PUBLIC_APP_NAME = "QVault"
        NEXT_PUBLIC_APP_URL  = "https://qvault.${local.internal_domain}"

        # qvault's exporters (@vercel/otel + otlp-proto) speak http/protobuf
        # only, which is Aspire's 18890 listener -- 18889 is gRPC-only.
        OTEL_EXPORTER_OTLP_ENDPOINT = "http://${local.service_ips.aspire}:18890"
        OTEL_SERVICE_NAME           = "qvault"
        OTEL_EXPORTER_OTLP_PROTOCOL = "http/protobuf"
      }
    },
    {
      name       = "caddy"
      image      = "docker.io/library/caddy:latest"
      ports      = ["80:80", "443:443"]
      depends_on = ["qvault"]
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
# Penpot
# ---------------------------------------------------------------------------
module "penpot" {
  source    = "./modules/vm"
  providers = { libvirt = libvirt.vhost }

  name             = "penpot-vm"
  pool_name        = libvirt_pool.vhost.name
  base_volume_path = libvirt_volume.base_vhost.path
  vcpu             = 6
  memory_mib       = 4096
  disk_gib         = 15
  bridge           = var.vhost_bridge
  static_ip        = "${local.service_ips.penpot}${var.vhost_lan_cidr_suffix}"
  gateway          = var.vhost_gateway
  dns              = local.vm_dns
  firmware         = var.uefi_firmware
  nvram_template   = var.uefi_nvram_template
  vm_user          = var.vm_user
  ssh_public_key   = trimspace(file(pathexpand(var.ssh_public_key_path)))

  extra_files = local.caddy_extra_files.penpot

  containers = [
    {
      name  = "penpot-postgres"
      image = "docker.io/library/postgres:15"
      environment = {
        POSTGRES_USER     = local.secret_usernames.penpot_postgres_password
        POSTGRES_PASSWORD = local.secrets_values.penpot_postgres_password
        POSTGRES_DB       = "penpot"
      }
      volumes = ["penpot-postgres-data:/var/lib/postgresql/data"]
    },
    {
      name  = "penpot-redis"
      image = "docker.io/library/redis:7"
    },
    {
      name       = "penpot-backend"
      image      = "docker.io/penpotapp/backend:latest"
      depends_on = ["penpot-postgres", "penpot-redis"]
      environment = {
        PENPOT_DATABASE_URI      = "postgresql://penpot-postgres/penpot"
        PENPOT_DATABASE_USERNAME = local.secret_usernames.penpot_postgres_password
        PENPOT_DATABASE_PASSWORD = local.secrets_values.penpot_postgres_password
        PENPOT_REDIS_URI         = "redis://penpot-redis/0"
        PENPOT_SECRET_KEY        = local.secrets_values.penpot_secret_key
        PENPOT_FLAGS             = local.penpot_flags
        PENPOT_PUBLIC_URI        = "https://penpot.${local.internal_domain}"
      }
      volumes = ["penpot-assets:/opt/data/assets"]
    },
    {
      name       = "penpot-exporter"
      image      = "docker.io/penpotapp/exporter:latest"
      depends_on = ["penpot-backend", "penpot-redis"]
      environment = {
        PENPOT_PUBLIC_URI = "https://penpot.${local.internal_domain}"
        PENPOT_REDIS_URI  = "redis://penpot-redis/0"
        PENPOT_SECRET_KEY = local.secrets_values.penpot_secret_key
      }
    },
    {
      name       = "penpot-frontend"
      image      = "docker.io/penpotapp/frontend:latest"
      ports      = ["9001:8080"]
      depends_on = ["penpot-backend", "penpot-exporter"]
      environment = {
        PENPOT_FLAGS = local.penpot_flags
      }
      volumes = ["penpot-assets:/opt/data/assets"]
    },
    {
      name       = "caddy"
      image      = "docker.io/library/caddy:latest"
      ports      = ["80:80", "443:443"]
      depends_on = ["penpot-frontend"]
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
# Monitoring: Prometheus + Grafana
# ---------------------------------------------------------------------------
locals {
  # HTTP(S) web services to blackbox-probe. Module: http_2xx (GET, follow
  # redirects, any 2xx). Aspire's dashboard is an OTLP/grpc + rich UI host --
  # 18888 serves its HTML; probing / keeps it simple and catches a dead VM.
  blackbox_http_targets = [
    "https://qvault.${local.internal_domain}",
    "https://penpot.${local.internal_domain}",
    "https://grafana.${local.internal_domain}/api/health",
    "https://prometheus.${local.internal_domain}/-/healthy",
    "https://aspire.${local.internal_domain}",
    "https://registry.${local.internal_domain}/v2/", # 200 from the registry root means docker.io cache is serving
    "https://gitea.${local.internal_domain}",
    "https://verdaccio.${local.internal_domain}",
    # DoH load-balancer endpoint: https://dns.lab.internal/dns-query fronts
    # dns1/dns2 via L4 TLS passthrough on dns-lb (:443). A 200 from the DoH
    # endpoint means the full chain works: LB -> backend caddy (TLS) ->
    # coredns:8053. Probing the bare path returns 404 (caddy's catch-all); the
    # ?dns= param makes blackbox do a real DoH query (HTTP GET with dns
    # parameter per RFC 8484).
    #
    # The ?dns= base64 MUST be a well-formed wire-format query or CoreDNS
    # answers FORMERR (HTTP 400) and the probe spikes EndpointDown even though
    # DNS itself is up (root cause of the 2026-09-02 "dns down" alert). The old
    # literal here (`AAABAAAB...`) had QID in the wrong byte order (QID=0x0000,
    # flags=0x0001) and was rejected. The value below is a correctly-built
    # query for `roo.lab.internal` A (produced by scripts/doh-probe.py's
    # build_query; verified HTTP 200 against the live LB).
    "https://dns.${local.internal_domain}/dns-query?dns=EjQBAAABAAAAAAAAA3JvbwNsYWIIaW50ZXJuYWwAAAEAAQ",
    # Also probe dns2's vhost directly (it's quietly covered by dns's SAN, but
    # a direct target catches a broken dns.lab -> dns backend mapping on the LB).
    "https://dns2.${local.internal_domain}/dns-query?dns=EjQBAAABAAAAAAAAA3JvbwNsYWIIaW50ZXJuYWwAAAEAAQ",
  ]

  # Non-HTTP endpoints worth a TCP liveness check (no app-level probe; a
  # refused connection is the actionable failure here).
  blackbox_tcp_targets = [
    "${local.service_ips.postgres}:5432",
    "${local.service_ips.surrealdb}:8000",
    "${local.service_ips.nfs}:2049",
    "${local.service_ips.gitea}:2222",
    "${local.service_ips.redis}:6379",
  ]

  # DNS answers are load-bearing for the whole lab -- probe that each CoreDNS
  # instance actually resolves the zone, not just that the port accepts
  # connections. blackbox's dns module does a full question/answer round-trip.
  # DNS health checks hit the load balancer (dns.lab.internal) plus both
  # backends directly, so a single failed CoreDNS behind a still-answering LB
  # is still detected.
  blackbox_dns_targets = [
    "${local.service_ips.dns-lb}:53",
    "${local.service_ips.dns1}:53",
    "${local.service_ips.dns2}:53",
  ]

  prometheus_config = <<-YAML
    global:
      scrape_interval: 15s
      evaluation_interval: 15s

    rule_files:
      - /etc/prometheus/rules/*.yml

    alerting:
      alertmanagers:
        - static_configs:
            - targets: ["alertmanager:9093"]

    scrape_configs:
      - job_name: prometheus
        static_configs:
          - targets: ["localhost:9090"]
      - job_name: alertmanager
        static_configs:
          - targets: ["alertmanager:9093"]
      - job_name: node-exporters
        static_configs:
          - targets:
              - "${local.service_ips.surrealdb}:9100"
              - "${local.service_ips.postgres}:9100"
              - "${local.service_ips.qvault}:9100"
              - "${local.service_ips.penpot}:9100"
              - "${local.service_ips.dns1}:9100"
              - "${local.service_ips.dns2}:9100"
              - "${local.service_ips.ca}:9100"
              - "${local.service_ips.registry}:9100"
              - "${local.service_ips.gitea}:9100"
              - "${local.service_ips.verdaccio}:9100"
              - "${local.service_ips.nfs}:9100"
              - "${local.service_ips.redis}:9100"
              - "${local.gitea_runner_ips["gitea-runner-1"]}:9100"
              - "${local.gitea_runner_ips["gitea-runner-2"]}:9100"
              - "node-exporter:9100"
      - job_name: postgres
        static_configs:
          - targets: ["${local.service_ips.postgres}:9187"]
      - job_name: redis
        static_configs:
          - targets: ["${local.service_ips.redis}:9121"]
      - job_name: coredns
        static_configs:
          - targets:
              - "${local.service_ips.dns1}:9153"
              - "${local.service_ips.dns2}:9153"
      # Uptime probes. The exporter runs as a sibling container (blackbox:9115);
      # relabelling swaps the *reported* instance to the probe target so the
      # alert/user sees e.g. instance="https://gitea.lab.internal", not the
      # exporter's own address. Based on the stock blackbox example:
      # https://github.com/prometheus/blackbox_exporter#prometheus-configuration
      - job_name: blackbox-http
        metrics_path: /probe
        params:
          module: [http_2xx]
        static_configs:
          - targets:
%{for t in local.blackbox_http_targets~}
              - "${t}"
%{endfor~}
        relabel_configs:
          - source_labels: [__address__]
            target_label: __param_target
          - source_labels: [__param_target]
            target_label: instance
          - target_label: __address__
            replacement: blackbox:9115
      - job_name: blackbox-tcp
        metrics_path: /probe
        params:
          module: [tcp_connect]
        static_configs:
          - targets:
%{for t in local.blackbox_tcp_targets~}
              - "${t}"
%{endfor~}
        relabel_configs:
          - source_labels: [__address__]
            target_label: __param_target
          - source_labels: [__param_target]
            target_label: instance
          - target_label: __address__
            replacement: blackbox:9115
      - job_name: blackbox-dns
        metrics_path: /probe
        params:
          module: [dns_lab_internal]
        static_configs:
          - targets:
%{for t in local.blackbox_dns_targets~}
              - "${t}"
%{endfor~}
        relabel_configs:
          - source_labels: [__address__]
            target_label: __param_target
          - source_labels: [__param_target]
            target_label: instance
          - target_label: __address__
            replacement: blackbox:9115
  YAML

  # Uptime rules. probe_success==0 is the primary signal ("is it up"); the
  # duration alert separately catches "responding but pathologically slow".
  # `for` delays keep a single missed scrape or transient flap from paging you,
  # and Alertmanager also routes on severity (critical=ntfy priority 5).
  prometheus_alert_rules = <<-YAML
    groups:
      - name: uptime
        rules:
          - alert: EndpointDown
            expr: probe_success == 0
            for: 2m
            labels:
              severity: critical
            annotations:
              summary: "Endpoint down: {{ $labels.instance }}"
              description: "{{ $labels.job }} probe of {{ $labels.instance }} has failed for 2 minutes."
          - alert: EndpointSlow
            expr: probe_duration_seconds > 5
            for: 5m
            labels:
              severity: warning
            annotations:
              summary: "Endpoint slow: {{ $labels.instance }}"
              description: "{{ $labels.instance }} is taking over 5s to respond (blackbox probe)."
          # Watchdog: a permanently-firing alert so a broken alerting
          # pipeline itself is visible (ntfy shows this firing whenever the
          # stack is up; if it disappears, alerting is broken end-to-end).
          - alert: Watchdog
            expr: vector(1)
            labels:
              severity: info
            annotations:
              summary: "Watchdog (alerting pipeline alive)"
  YAML

  # Blackbox exporter modules. The dns module asks each CoreDNS instance for
  # gitea.lab.internal and REQUIRES a valid answer -- this is what tells you
  # "DNS is serving the zone", vs. tcp_connect which would pass on a half-dead
  # coredns that accepts then drops queries.
  blackbox_config = <<-YAML
    modules:
      http_2xx:
        prober: http
        timeout: 10s
        http:
          valid_http_versions: ["HTTP/1.1", "HTTP/2.0"]
          follow_redirects: true
          preferred_ip_protocol: ip4
          # Trust the lab root CA: the exporter runs against the step-ca-
          # issued certs on the per-VM Caddy front-ends, which the public
          # PKI doesn't know.
          tls_config:
            ca_file: /etc/blackbox/root_ca.crt
      tcp_connect:
        prober: tcp
        timeout: 5s
      dns_lab_internal:
        prober: dns
        timeout: 5s
        dns:
          query_name: gitea.lab.internal
          query_type: A
          valid_rcodes: [NOERROR]
          validate_answer_rrs:
            fail_if_not_matches_regexp: [".*"]
  YAML

  # Alertmanager posts to the ntfy container by name over the shared podman
  # user network (vmnet). The random topic is the only access control -- keep
  # it in state like the other generated credentials. ntfy_priority 5 =
  # "urgent" (phone makes sound/vibrates even on DND bypass if configured).
  alertmanager_config = <<-YAML
    route:
      receiver: ntfy
      group_by: [alertname, instance]
      group_wait: 30s
      group_interval: 5m
      repeat_interval: 4h
    receivers:
      - name: ntfy
        webhook_configs:
          # Sends the whole alert-group JSON to the local shim (ntfy-shim:8901),
          # which renders it into a clean ntfy publish (title + body + priority
          # headers). Alertmanager's webhook_configs cannot format the message
          # itself, and its http_config has no `headers` field (an earlier
          # version set one and crash-looped Alertmanager on startup).
          - url: "http://ntfy-shim:8901/alert"
            send_resolved: true
  YAML

  # Tiny webhook->ntfy formatter. Alertmanager can only POST its alert-group
  # JSON; this shim turns it into a readable ntfy publish with severity-mapped
  # priority (what the raw-webhook path cannot do). Stdlib only, no deps.
  ntfy_shim_py = <<-PY
    import json, urllib.request
    from http.server import BaseHTTPRequestHandler, HTTPServer

    TOPIC = "${local.secrets_values.ntfy_alert_topic}"
    NTFY = "http://ntfy/" + TOPIC
    PRIORITY = {"critical": "5", "warning": "3"}
    ICON = {"firing": "rotating_light", "resolved": "white_check_mark"}

    class H(BaseHTTPRequestHandler):
        def do_POST(self):
            n = int(self.headers.get("Content-Length", 0))
            try:
                g = json.loads(self.rfile.read(n) or b"{}")
                alerts = g.get("alerts", [{}])
                a = alerts[0]
                status = g.get("status", "firing")
                labels = a.get("labels", {})
                ann = a.get("annotations", {})
                name = labels.get("alertname", "Alert")
                inst = labels.get("instance", "")
                sev = labels.get("severity", "warning")
                title = f"[{status.upper()}] {name}" + (f" - {inst}" if inst else "")
                body = ann.get("description") or ann.get("summary") or name
                if len(alerts) > 1:
                    body += f" (+{len(alerts) - 1} more)"
                req = urllib.request.Request(NTFY, data=body.encode(), headers={
                    "Title": title,
                    "Priority": PRIORITY.get(sev, "3"),
                    "Tags": ICON.get(status, "bell"),
                })
                urllib.request.urlopen(req, timeout=10)
                self.send_response(200)
            except Exception as e:
                self.send_response(500)
            finally:
                self.end_headers()

        def log_message(self, *args):
            pass

    HTTPServer(("0.0.0.0", 8901), H).serve_forever()
  PY

  # ntfy server. No auth: the topic is an un-guessable random string and the
  # VM is LAN-private. base-url so the phone-app subscribe URL renders right.
  ntfy_config = <<-YAML
    base-url: "https://ntfy.${local.internal_domain}"
    listen-http: ":80"
    behind-proxy: true
  YAML

  grafana_datasource = <<-YAML
    apiVersion: 1
    datasources:
      - name: Prometheus
        type: prometheus
        access: proxy
        url: http://prometheus:9090
        isDefault: true
  YAML
}

module "monitoring" {
  source    = "./modules/vm"
  providers = { libvirt = libvirt.vhost }

  name             = "monitoring-vm"
  pool_name        = libvirt_pool.vhost.name
  base_volume_path = libvirt_volume.base_vhost.path
  vcpu             = 4
  memory_mib       = 2048
  # Grew with the alerting stack (alertmanager + blackbox + ntfy); still small
  # because nothing on this VM stores bulk data beyond prometheus-data.
  #
  # auto_sync was temporarily disabled for a disk-replace rebuild; a fresh boot
  # runs cloud-init automatically (no SSH race). Re-enabled after verification.
  auto_sync      = true
  disk_gib       = 25
  bridge         = var.vhost_bridge
  static_ip      = "${local.service_ips.monitoring}${var.vhost_lan_cidr_suffix}"
  gateway        = var.vhost_gateway
  dns            = local.vm_dns
  firmware       = var.uefi_firmware
  nvram_template = var.uefi_nvram_template
  vm_user        = var.vm_user
  ssh_public_key = trimspace(file(pathexpand(var.ssh_public_key_path)))

  extra_files = concat(
    [
      { path = "/etc/monitoring/prometheus.yml", content = local.prometheus_config },
      { path = "/etc/monitoring/rules/uptime.yml", content = local.prometheus_alert_rules },
      { path = "/etc/monitoring/alertmanager.yml", content = local.alertmanager_config },
      { path = "/etc/monitoring/blackbox.yml", content = local.blackbox_config },
      { path = "/etc/monitoring/ntfy-server.yml", content = local.ntfy_config },
      { path = "/etc/monitoring/ntfy-shim.py", content = local.ntfy_shim_py, permissions = "0755" },
      { path = "/etc/monitoring/grafana-datasource.yml", content = local.grafana_datasource },
      # The blackbox exporter needs the lab root CA to trust step-ca-issued
      # TLS certs on the services it probes. Mounting the same file used for
      # the OS trust store keeps it one source of truth.
      { path = "/etc/monitoring/root_ca.crt", content = local.root_ca_cert_pem },
    ],
    local.caddy_extra_files.monitoring,
  )

  containers = [
    {
      name  = "node-exporter"
      image = "quay.io/prometheus/node-exporter:latest"
      ports = ["9100:9100"]
    },
    {
      name  = "prometheus"
      image = "docker.io/prom/prometheus:latest"
      ports = ["9090:9090"]
      # --web.external-url keeps generated links right when browsing through
      # caddy at https://prometheus.lab.internal (caddy strips no path, so a
      # path prefix isn't needed; just the scheme/host).
      command = "--config.file=/etc/prometheus/prometheus.yml --storage.tsdb.path=/prometheus --storage.tsdb.retention.time=30d --web.enable-lifecycle"
      volumes = [
        "/etc/monitoring/prometheus.yml:/etc/prometheus/prometheus.yml:Z",
        "/etc/monitoring/rules:/etc/prometheus/rules:Z",
        "prometheus-data:/prometheus",
      ]
    },
    {
      name       = "alertmanager"
      image      = "docker.io/prom/alertmanager:latest"
      ports      = ["9093:9093"]
      depends_on = ["prometheus"]
      volumes = [
        "/etc/monitoring/alertmanager.yml:/etc/alertmanager/alertmanager.yml:Z",
        "alertmanager-data:/alertmanager",
      ]
    },
    {
      name       = "blackbox"
      image      = "quay.io/prometheus/blackbox-exporter:latest"
      ports      = ["9115:9115"]
      depends_on = ["prometheus"]
      command    = "--config.file=/etc/blackbox/blackbox.yml"
      volumes = [
        "/etc/monitoring/blackbox.yml:/etc/blackbox/blackbox.yml:Z",
        "/etc/monitoring/root_ca.crt:/etc/blackbox/root_ca.crt:Z",
      ]
    },
    {
      name  = "ntfy"
      image = "docker.io/binwiederhier/ntfy:latest"
      # Host port 8086: caddy reverse-proxies https://ntfy.lab.internal here so
      # the phone app (with the lab root CA trusted) can subscribe from the LAN.
      ports   = ["8086:80"]
      command = "serve"
      volumes = [
        "/etc/monitoring/ntfy-server.yml:/etc/ntfy/server.yml:Z",
        "ntfy-data:/var/cache/ntfy",
      ]
    },
    {
      # Alertmanager -> ntfy translator: turns the raw alert-group JSON into a
      # readable publish (title + body + severity-mapped priority). Not exposed
      # to the LAN; only needs to reach alertmanager's webhook and the ntfy
      # container over the shared vmnet network.
      name       = "ntfy-shim"
      image      = "docker.io/library/python:3-alpine"
      depends_on = ["ntfy"]
      command    = "python /etc/monitoring/ntfy-shim.py"
      volumes    = ["/etc/monitoring/ntfy-shim.py:/etc/monitoring/ntfy-shim.py:Z"]
    },
    {
      name  = "grafana"
      image = "docker.io/grafana/grafana:latest"
      ports = ["3001:3000"]
      environment = {
        GF_SECURITY_ADMIN_USER     = local.secret_usernames.grafana_admin_password
        GF_SECURITY_ADMIN_PASSWORD = local.secrets_values.grafana_admin_password
        GF_SERVER_ROOT_URL         = "https://grafana.${local.internal_domain}"
      }
      volumes = [
        "/etc/monitoring/grafana-datasource.yml:/etc/grafana/provisioning/datasources/prometheus.yml:Z",
        "grafana-data:/var/lib/grafana",
      ]
    },
    {
      name       = "caddy"
      image      = "docker.io/library/caddy:latest"
      ports      = ["80:80", "443:443"]
      depends_on = ["grafana", "prometheus", "ntfy"]
      # Caddyfile now fronts ntfy too (local.caddy_sites.monitoring gains an
      # ntfy entry so the phone app can subscribe via the step-ca cert).
      volumes = [
        "/etc/infra/Caddyfile:/etc/caddy/Caddyfile:Z",
        "/etc/infra/root_ca.crt:/etc/caddy/root_ca.crt:Z",
        "caddy-data:/data",
      ]
    },
  ]
}

# ---------------------------------------------------------------------------
# .NET Aspire Dashboard (OTLP receiver for qvault)
# ---------------------------------------------------------------------------
module "aspire" {
  source    = "./modules/vm"
  providers = { libvirt = libvirt.vhost }

  name             = "aspire-vm"
  pool_name        = libvirt_pool.vhost.name
  base_volume_path = libvirt_volume.base_vhost.path
  vcpu             = 2
  memory_mib       = 2048
  disk_gib         = 5
  bridge           = var.vhost_bridge
  static_ip        = "${local.service_ips.aspire}${var.vhost_lan_cidr_suffix}"
  gateway          = var.vhost_gateway
  dns              = local.vm_dns
  firmware         = var.uefi_firmware
  nvram_template   = var.uefi_nvram_template
  vm_user          = var.vm_user
  ssh_public_key   = trimspace(file(pathexpand(var.ssh_public_key_path)))

  extra_files = local.caddy_extra_files.aspire

  containers = [
    {
      name  = "aspire-dashboard"
      image = "mcr.microsoft.com/dotnet/aspire-dashboard:latest"
      # 18889 = OTLP/gRPC, 18890 = OTLP/HTTP (qvault exports http/protobuf)
      ports = ["18888:18888", "18889:18889", "18890:18890"]
      environment = {
        DASHBOARD__FRONTEND__AUTHMODE = "Unsecured"
        DASHBOARD__OTLP__AUTHMODE     = "Unsecured"
      }
    },
    {
      name       = "caddy"
      image      = "docker.io/library/caddy:latest"
      ports      = ["80:80", "443:443"]
      depends_on = ["aspire-dashboard"]
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
# Uses the standalone Postgres VM (192.168.70.11) as its DB. An init sidecar
# creates the `giteadb` database on first boot; the server container then
# Gitea-migrates its own schema on startup.
# ---------------------------------------------------------------------------
locals {
  gitea_db_host = local.service_ips.postgres
  gitea_db_name = "giteadb"
  gitea_db_user = local.secret_usernames.gitea_db_password
  gitea_db_pass = local.secrets_values.gitea_db_password

  # Run on the gitea VM itself; connects to the shared postgres VM over the
  # LAN as the postgres superuser (the role created by the postgres VM's
  # POSTGRES_PASSWORD) to provision the gitea role + database idempotently.
  gitea_init_script = <<-EOT
    #!/bin/sh
    # Idempotently provision the gitea role + database on the shared postgres
    # VM. Avoids nested-heredoc dollar-quoting (a prior version's escaped
    # \$\$ was rejected by psql); uses ON_ERROR_STOP single statements and a
    # wait-for-postgres retry loop so first boot doesn't race postgres startup.
    set -e
    export PGPASSWORD='${local.secrets_values.postgres_password}'
    export PGCONNECT_TIMEOUT=5

    # Wait for postgres to accept connections (bounded) before provisioning.
    tries=0
    until psql -h ${local.gitea_db_host} -U ${local.secret_usernames.postgres_password} -d postgres -c 'SELECT 1' >/dev/null 2>&1; do
      tries=$((tries + 1))
      if [ "$tries" -ge 30 ]; then
        echo "postgres at ${local.gitea_db_host} not ready after $tries attempts" >&2
        exit 1
      fi
      sleep 2
    done

    # Create or update the gitea role (always (re)set the password).
    psql -h ${local.gitea_db_host} -U ${local.secret_usernames.postgres_password} -d postgres -v ON_ERROR_STOP=1 \
      -c "CREATE ROLE ${local.gitea_db_user} LOGIN PASSWORD '${local.gitea_db_pass}'" \
      || psql -h ${local.gitea_db_host} -U ${local.secret_usernames.postgres_password} -d postgres -v ON_ERROR_STOP=1 \
      -c "ALTER ROLE ${local.gitea_db_user} WITH LOGIN PASSWORD '${local.gitea_db_pass}'"

    # Create the database if missing (CREATE DATABASE can't run in a DO block).
    if ! psql -h ${local.gitea_db_host} -U ${local.secret_usernames.postgres_password} -d postgres -tAc \
      "SELECT 1 FROM pg_database WHERE datname='${local.gitea_db_name}'" | grep -q 1; then
      psql -h ${local.gitea_db_host} -U ${local.secret_usernames.postgres_password} -d postgres -v ON_ERROR_STOP=1 \
        -c "CREATE DATABASE ${local.gitea_db_name} OWNER ${local.gitea_db_user}"
    fi

    # Ensure ownership is correct even if the db pre-existed.
    psql -h ${local.gitea_db_host} -U ${local.secret_usernames.postgres_password} -d postgres -v ON_ERROR_STOP=1 \
      -c "ALTER DATABASE ${local.gitea_db_name} OWNER TO ${local.gitea_db_user}"
  EOT
}

module "gitea" {
  source    = "./modules/vm"
  providers = { libvirt = libvirt.vhost }

  name             = "gitea-vm"
  pool_name        = libvirt_pool.vhost.name
  base_volume_path = libvirt_volume.base_vhost.path
  vcpu             = 2
  memory_mib       = 4096
  # Root disk holds only the OS + podman image layers; all repos/LFS live on
  # the NFS export (/var/lib/gitea -> container /data) and the DB is on the
  # shared postgres VM, so a small root disk is all the VM needs.
  disk_gib       = 5
  bridge         = var.vhost_bridge
  static_ip      = "${local.service_ips.gitea}${var.vhost_lan_cidr_suffix}"
  gateway        = var.vhost_gateway
  dns            = local.vm_dns
  firmware       = var.uefi_firmware
  nvram_template = var.uefi_nvram_template
  vm_user        = var.vm_user
  ssh_public_key = trimspace(file(pathexpand(var.ssh_public_key_path)))

  # nfs-utils pulls in mount.nfs4 + rpc.statd needed for the fstab entry
  # below; the gitea container's data dir lives on the nfs VM.
  extra_packages = ["nfs-utils"]

  extra_files = concat(
    [
      { path = "/etc/infra/gitea/init-db.sh", content = local.gitea_init_script, permissions = "0755" },
      {
        path        = "/etc/infra/gitea/gitea.nfs.fstab"
        permissions = "0644"
        # x-systemd.before targets the quadlet-generated unit name (container
        # name + .service), i.e. gitea.service -- NOT podman-gitea.service.
        content = "${local.service_ips.nfs}:/gitea /var/lib/gitea nfs4 rw,hard,intr,noatime,_netdev,x-systemd.automount,x-systemd.idle-timeout=600,x-systemd.before=gitea.service 0 0\n"
      },
    ],
    local.caddy_extra_files.gitea,
  )

  extra_runcmd = [
    # Register the NFS mount in fstab and activate it now (cloud-init does
    # not process fstab on first boot once the system is already up);
    # daemon-reload in runcmd above has already run by the time this fires.
    # The grep guard keeps cloud-init re-rolls (`cloud-init clean && reboot`,
    # e.g. a fleet-wide quadlet refresh) from appending the line twice.
    ["mkdir", "-p", "/var/lib/gitea"],
    ["sh", "-c", "grep -qF ':/gitea /var/lib/gitea' /etc/fstab || cat /etc/infra/gitea/gitea.nfs.fstab >> /etc/fstab"],
    ["systemctl", "daemon-reload"],
    ["mount", "/var/lib/gitea"],
  ]

  containers = [
    {
      # Oneshot bootstrap: creates the gitea role + database on the shared
      # postgres VM. The postgres image's `psql` is enough; we connect over
      # the LAN to the postgres VM:5432.
      name       = "gitea-db-init"
      image      = "docker.io/library/postgres:16"
      command    = "/etc/infra/gitea/init-db.sh"
      volumes    = ["/etc/infra/gitea/init-db.sh:/etc/infra/gitea/init-db.sh:Z"]
      depends_on = []
      oneshot    = true
    },
    {
      name  = "gitea"
      image = "docker.io/gitea/gitea:1"
      # Host port 2222 forwards to the container's sshd on port 22.
      # Gitea itself only listens on 3000 (HTTP) and 22 (SSH) inside the container.
      ports      = ["2222:22"]
      depends_on = ["gitea-db-init"]
      environment = {
        GITEA__database__DB_TYPE        = "postgres"
        GITEA__database__HOST           = "${local.gitea_db_host}:5432"
        GITEA__database__NAME           = local.gitea_db_name
        GITEA__database__USER           = local.gitea_db_user
        GITEA__database__PASSWD         = local.gitea_db_pass
        GITEA__server__DOMAIN           = "gitea.${local.internal_domain}"
        GITEA__server__ROOT_URL         = "https://gitea.${local.internal_domain}/"
        GITEA__server__SSH_DOMAIN       = "gitea.${local.internal_domain}"
        GITEA__server__SSH_PORT         = "2222"
        GITEA__security__INSTALL_LOCK   = "true"
        GITEA__security__INTERNAL_TOKEN = local.secrets_values.gitea_internal_token
        GITEA__security__SECRET_KEY     = local.secrets_values.gitea_secret_key
        GITEA__oauth2__JWT_SECRET       = local.secrets_values.gitea_jwt_secret
        GITEA__log__LEVEL               = "Info"
      }
      # Bind mount, not a named volume: /var/lib/gitea is the NFS export on
      # the nfs VM, so rebuilding this VM (even replacing its root disk)
      # keeps the git repos. Replaces the old gitea-data named volume.
      volumes = ["/var/lib/gitea:/data:Z"]
    },
    {
      name       = "caddy"
      image      = "docker.io/library/caddy:latest"
      ports      = ["80:80", "443:443"]
      depends_on = ["gitea"]
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
# Verdaccio: local npm registry. Caches npmjs.org pulls (uplink) and hosts
# the packages compiled from the source mirrors kept in Gitea. Auth uses the
# built-in htpasswd plugin with max_users: 1, so the first `npm adduser`
# against https://verdaccio.lab.internal becomes the publisher; subsequent
# publishes by that account populate the local store. Pulls for packages
# not yet published locally transparently fall through to the npmjs uplink
# and are cached on first hit.
# ---------------------------------------------------------------------------
locals {
  verdaccio_config = <<-YAML
    # Path to the verdaccio data directory (named volume mount point).
    storage: /verdaccio/storage
    plugins: /verdaccio/plugins

    web:
      title: Verdaccio (lab.internal)

    # Auth: the first user to run `npm adduser` against this registry is
    # created in htpasswd and becomes the sole publisher (max_users: 1).
    auth:
      htpasswd:
        file: /verdaccio/storage/htpasswd
        max_users: 1

    # Upstream npm registry used as a pull-through cache + fallback for any
    # package not yet published locally.
    uplinks:
      npmjs:
        url: https://registry.npmjs.org/
        cache: true

    packages:
      # Scoped and unscoped packages: publish is restricted to authenticated
      # users; unpublished/local packages transparently proxy npmjs and cache.
      "@*/*":
        access: $all
        publish: $authenticated
        unpublish: $authenticated
        proxy: npmjs
      "**":
        access: $all
        publish: $authenticated
        unpublish: $authenticated
        proxy: npmjs

    server:
      keepBodyTimeout: 10

    logs:
      - { type: stdout, format: pretty, level: http }

    # Bind on all interfaces inside the container; Caddy terminates TLS.
    listen: 0.0.0.0:4873
  YAML
}

module "verdaccio" {
  source    = "./modules/vm"
  providers = { libvirt = libvirt.vhost }

  name             = "verdaccio-vm"
  pool_name        = libvirt_pool.vhost.name
  base_volume_path = libvirt_volume.base_vhost.path
  vcpu             = 2
  memory_mib       = 2048
  disk_gib         = 20
  bridge           = var.vhost_bridge
  static_ip        = "${local.service_ips.verdaccio}${var.vhost_lan_cidr_suffix}"
  gateway          = var.vhost_gateway
  dns              = local.vm_dns
  firmware         = var.uefi_firmware
  nvram_template   = var.uefi_nvram_template
  vm_user          = var.vm_user
  ssh_public_key   = trimspace(file(pathexpand(var.ssh_public_key_path)))

  extra_files = concat(
    [
      { path = "/etc/infra/verdaccio/config.yaml", content = local.verdaccio_config },
    ],
    local.caddy_extra_files.verdaccio,
  )

  containers = [
    {
      name  = "verdaccio"
      image = "docker.io/verdaccio/verdaccio:6"
      ports = ["4873:4873"]
      volumes = [
        "/etc/infra/verdaccio/config.yaml:/verdaccio/conf/config.yaml:Z",
        "verdaccio-storage:/verdaccio/storage",
        "verdaccio-plugins:/verdaccio/plugins",
      ]
    },
    {
      name       = "caddy"
      image      = "docker.io/library/caddy:latest"
      ports      = ["80:80", "443:443"]
      depends_on = ["verdaccio"]
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
# NFS server: central durable store for service data that must survive a
# consumer VM rebuild (git repos first; other services can add exports later).
# Runs erichough/nfs-server (kernel NFS in a container), NFSv4-only on 2049.
# Exports live under /exports on a single podman named volume: replacing the
# nfs VM's disk still wipes data, but replacing any *consumer* (gitea, ...)
# does NOT -- that's the whole point.
# ---------------------------------------------------------------------------
locals {
  # Client CIDR allowed to mount. Only hosts with an address in the
  # service range may mount. The admin laptop joins it via a secondary
  # address (192.168.70.254/22 on the LAN interface) instead of widening
  # the export to the whole LAN supernet.
  nfs_client_cidr = "192.168.70.0/24"

  # Gitea runs as uid 1000 (user `git`) inside the container; squash all
  # client writes to that uid/gid so files it creates round-trip owned by
  # git regardless of client-side identity.
  # NFSv4 needs an fsid=0 pseudo-root: clients mount paths relative to it.
  # Without this line, mounting 192.168.70.22:/gitea fails with
  # "No such file or directory" because /gitea doesn't exist in the pseudo-fs.
  # The root must be rw: when a client mounts the child path through the
  # pseudo-root, the kernel attributes the mount to the fsid=0 export -- if
  # that root is ro, the child mount is silently ro too (observed on the
  # gitea VM). There is nothing to write into the root itself, so rw here
  # is not a real exposure.
  nfs_exports = <<-EOT
    /exports       ${local.nfs_client_cidr}(rw,async,no_subtree_check,no_root_squash,fsid=0)
    /exports/gitea ${local.nfs_client_cidr}(rw,async,no_subtree_check,no_root_squash,all_squash,anonuid=1000,anongid=1000)
  EOT
}

module "nfs" {
  source    = "./modules/vm"
  providers = { libvirt = libvirt.vhost }

  name             = "nfs-vm"
  pool_name        = libvirt_pool.vhost.name
  base_volume_path = libvirt_volume.base_vhost.path
  vcpu             = 1
  memory_mib       = 2048
  disk_gib         = 50
  bridge           = var.vhost_bridge
  static_ip        = "${local.service_ips.nfs}${var.vhost_lan_cidr_suffix}"
  gateway          = var.vhost_gateway
  dns              = local.vm_dns
  firmware         = var.uefi_firmware
  nvram_template   = var.uefi_nvram_template
  vm_user          = var.vm_user
  ssh_public_key   = trimspace(file(pathexpand(var.ssh_public_key_path)))

  extra_files = [
    { path = "/etc/infra/nfs/exports", content = local.nfs_exports, permissions = "0644" },
    # Load kernel nfsd on boot (the container entrypoint runs modprobe nfsd
    # but needs the host kernel to have it available; auto-load at boot).
    {
      path        = "/etc/modules-load.d/nfs.conf"
      permissions = "0644"
      content     = "nfs\nnfsd\n"
    },
  ]

  # Load now (one-off; the modules-load.d entry covers subsequent boots).
  # Also create the per-service export dirs inside the bind-mounted host
  # dir, with ownership matching the anonuid/anongid used in the exports
  # (1000:1000 for gitea), so the container's exportfs doesn't fail with
  # "No such file or Directory" and squash-mapped writes round-trip as the
  # caller-expected uid/gid.
  extra_runcmd = [
    ["modprobe", "nfs"],
    ["modprobe", "nfsd"],
    ["mkdir", "-p", "/srv/nfs/gitea"],
    ["chown", "1000:1000", "/srv/nfs/gitea"],
  ]

  containers = [
    {
      name  = "nfs-server"
      image = "docker.io/erichough/nfs-server:2.2.1"
      # NFSv4-only: kernel nfsd on 2049/tcp; no rpcbind/mountd/lockd needed
      # for v4, so no other ports get published. The image's entrypoint
      # accepts these flags to disable the legacy versions and listener.
      ports   = ["2049:2049"]
      command = "--no-udp --no-nfs-version 2 --no-nfs-version 3"
      # Container needs CAP_SYS_ADMIN / SETPCAP / MKNOD to load+run kernel
      # nfsd; extra_args maps to PodmanArgs= in the generated quadlet.
      extra_args = ["--privileged"]
      volumes = [
        "/etc/infra/nfs/exports:/etc/exports:Z",
        # Host bind mount (not named volume): we own /srv/nfs on the VM so
        # per-service export dirs have boot-time-controlled ownership.
        "/srv/nfs:/exports:Z",
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
# OpenBao secrets management — Transit-seal provider (openbao-transit-vm, .28)
# Dedicated Shamir-sealed OpenBao; this is the root of trust the main cluster's
# transit seal relies on. Operator unseals it manually after a transit-vm
# reboot. See plans/openbao-deployment.md.
# ---------------------------------------------------------------------------
module "openbao_transit" {
  source    = "./modules/vm"
  providers = { libvirt = libvirt.vhost }

  name             = "openbao-transit-vm"
  pool_name        = libvirt_pool.vhost.name
  base_volume_path = libvirt_volume.base_vhost.path
  vcpu             = 1
  memory_mib       = 512
  disk_gib         = 5
  bridge           = var.vhost_bridge
  static_ip        = "${local.service_ips.openbao-transit}${var.vhost_lan_cidr_suffix}"
  gateway          = var.vhost_gateway
  dns              = local.vm_dns
  firmware         = var.uefi_firmware
  nvram_template   = var.uefi_nvram_template
  vm_user          = var.vm_user
  ssh_public_key   = trimspace(file(pathexpand(var.ssh_public_key_path)))

  extra_files = [
    { path = "/etc/infra/openbao-transit/transit.hcl", content = local.transit_config },
    local.registry_mirror_file,
    local.root_ca_anchor_file,
  ]

  containers = [
    {
      name    = "openbao-transit"
      image   = "docker.io/openbao/openbao:2.6.2"
      command = "bao server -config=/openbao/config/transit.hcl"
      # Image's uid 100 can't write the root-owned mounted config/volume in
      # some cases; run as root so the root-only config stays readable and the
      # raft volume is writable (same rationale as other containers using 0).
      user  = "0"
      ports = ["8200:8200"]
      volumes = [
        "/etc/infra/openbao-transit/transit.hcl:/openbao/config/transit.hcl:Z",
        "transit-data:/openbao",
      ]
      # IPC_LOCK lets raft mlock (openbao recommends it).
      extra_args = ["--cap-add", "IPC_LOCK"]
    },
    {
      name  = "node-exporter"
      image = "quay.io/prometheus/node-exporter:latest"
      ports = ["9100:9100"]
    },
  ]
}

# ---------------------------------------------------------------------------
# OpenBao secrets management — Main cluster (openbao-vm, .27)
# Single-node Raft, TLS via caddy (step-ca ACME for openbao.lab.internal),
# auto-unseal via the transit provider above. See plans/openbao-deployment.md.
# ---------------------------------------------------------------------------
module "openbao" {
  source    = "./modules/vm"
  providers = { libvirt = libvirt.vhost }

  name             = "openbao-vm"
  pool_name        = libvirt_pool.vhost.name
  base_volume_path = libvirt_volume.base_vhost.path
  vcpu             = 2
  memory_mib       = 2048
  disk_gib         = 10
  bridge           = var.vhost_bridge
  static_ip        = "${local.service_ips.openbao}${var.vhost_lan_cidr_suffix}"
  gateway          = var.vhost_gateway
  dns              = local.vm_dns
  firmware         = var.uefi_firmware
  nvram_template   = var.uefi_nvram_template
  vm_user          = var.vm_user
  ssh_public_key   = trimspace(file(pathexpand(var.ssh_public_key_path)))

  # caddy_extra_files.openbao supplies the generated Caddyfile + root_ca.crt +
  # trust anchor + registry mirror for this VM (from local.caddy_sites). The
  # openbao.hcl.tmpl is the template the runtime config-render step fills with
  # the out-of-band transit token; it is NOT the final config path.
  extra_files = concat(
    local.caddy_extra_files.openbao,
    [
      { path = "/etc/infra/openbao/openbao.hcl.tmpl", content = local.openbao_config },
    ],
  )

  containers = [
    {
      name  = "openbao"
      image = "docker.io/openbao/openbao:2.6.2"
      # The quadlet mounts the final config at /openbao/config/openbao.hcl (see
      # the Volume below), so `bao server` reads it directly — no shell wrapper
      # (quadlet Exec= quoting strips quotes and splits on spaces, so a `sh -c`
      # image command would mis-parse). The operator materialises
      # /etc/infra/openbao/openbao.hcl from openbao.hcl.tmpl via the runbook;
      # the default template is Shamir (no seal block), so it starts cleanly.
      command = "bao server -config=/openbao/config/openbao.hcl"
      user    = "0"
      ports   = ["8200:8200"]
      volumes = [
        "/etc/infra/openbao/openbao.hcl:/openbao/config/openbao.hcl:Z",
        "openbao-data:/openbao",
      ]
      extra_args = ["--cap-add", "IPC_LOCK"]
    },
    {
      name       = "caddy"
      image      = "docker.io/library/caddy:latest"
      ports      = ["80:80", "443:443"]
      depends_on = ["openbao"]
      # Pin ca.lab.internal so ACME works before/without internal DNS (same as
      # the dns caddies).
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
