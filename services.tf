locals {
  service_ips = {
    surrealdb  = "192.168.70.10"
    postgres   = "192.168.70.11"
    qvault     = "192.168.70.12"
    penpot     = "192.168.70.13"
    monitoring = "192.168.70.14"
    aspire     = "192.168.70.15"
    dns        = "192.168.70.16"
    registry   = "192.168.70.17"
    ca         = "192.168.70.18"
    dns2       = "192.168.70.19"
    gitea      = "192.168.70.20"
    verdaccio  = "192.168.70.21"
  }

  # Shared by penpot-backend (enforcement) and penpot-frontend (UI rendering
  # of the register/login forms) -- both containers must see the same flags.
  # No SMTP is configured, so email verification must stay off for
  # self-registration to complete.
  penpot_flags = "enable-registration enable-login-with-password disable-email-verification"

  # Service VMs resolve ONLY through the internal CoreDNS instances (which
  # forward public names upstream). Both are authoritative for lab.internal,
  # so either may answer any query. Never add a public fallback here:
  # systemd-resolved treats all servers as equivalent and accepts a public
  # server's NXDOMAIN for lab.internal as final.
  vm_dns = [local.service_ips.dns, local.service_ips.dns2]

  # The root CA's private key only ever lived in tfstate (see pki.tf) and was
  # lost along with it. The public cert is not secret and is already trusted
  # everywhere, so it's captured here as a checked-in file instead of being
  # re-derived from the (now unrecoverable) tls_self_signed_cert.root
  # resource -- keeps every VM's trust anchor byte-identical to what's
  # actually deployed, without depending on a resource we can never bring
  # back into state.
  root_ca_cert_pem = file("${path.module}/pki/root-ca-cert.pem")

  # Caddyfiles for the per-VM reverse proxies, keyed by VM. Certs come from
  # step-ca on the infra VM via ACME; acme_ca_root trusts its TLS endpoint.
  caddy_sites = {
    qvault     = { qvault = "qvault:3000" }
    penpot     = { penpot = "penpot-frontend:8080" }
    monitoring = { grafana = "grafana:3000", prometheus = "prometheus:9090" }
    aspire     = { aspire = "aspire-dashboard:18888" }
    registry   = { registry = "registry:5000" }
    gitea      = { gitea = "gitea:3000" }
    verdaccio  = { verdaccio = "verdaccio:4873" }
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

  # docker.io pulls go through the cache on the registry VM (TLS via its
  # Caddy); podman falls back to docker.io directly if the mirror is
  # unreachable.
  registry_mirror_file = {
    path    = "/etc/containers/registries.conf.d/50-docker-mirror.conf"
    content = <<-EOT
      [[registry]]
      prefix = "docker.io"
      location = "docker.io"

      [[registry.mirror]]
      location = "registry.${local.internal_domain}"
    EOT
  }
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
  memory_mib       = 8192
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
        SURREAL_USER = "root"
        SURREAL_PASS = random_password.surrealdb_root.result
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
  memory_mib       = 8192
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

  containers = [
    {
      name  = "postgres"
      image = "docker.io/library/postgres:16"
      ports = ["5432:5432"]
      environment = {
        POSTGRES_PASSWORD = random_password.postgres.result
      }
      volumes = ["postgres-data:/var/lib/postgresql/data"]
    },
    {
      name       = "postgres-exporter"
      image      = "quay.io/prometheuscommunity/postgres-exporter:latest"
      ports      = ["9187:9187"]
      depends_on = ["postgres"]
      environment = {
        DATA_SOURCE_NAME = "postgresql://postgres:${random_password.postgres.result}@postgres:5432/postgres?sslmode=disable"
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
# qvault
# ---------------------------------------------------------------------------
module "qvault" {
  source    = "./modules/vm"
  providers = { libvirt = libvirt.vhost }

  name             = "qvault-vm"
  pool_name        = libvirt_pool.vhost.name
  base_volume_path = libvirt_volume.base_vhost.path
  vcpu             = 4
  memory_mib       = 4096
  disk_gib         = 15
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
        SURREALDB_USER       = "root"
        SURREALDB_PASS       = random_password.surrealdb_root.result
        SESSION_SECRET       = random_password.qvault_session_secret.result
        SERVER_SECRET        = random_password.qvault_server_secret.result
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
  memory_mib       = 8192
  disk_gib         = 30
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
        POSTGRES_USER     = "penpot"
        POSTGRES_PASSWORD = random_password.penpot_postgres.result
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
        PENPOT_DATABASE_USERNAME = "penpot"
        PENPOT_DATABASE_PASSWORD = random_password.penpot_postgres.result
        PENPOT_REDIS_URI         = "redis://penpot-redis/0"
        PENPOT_SECRET_KEY        = random_password.penpot_secret_key.result
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
        PENPOT_SECRET_KEY = random_password.penpot_secret_key.result
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
  prometheus_config = <<-YAML
    global:
      scrape_interval: 15s
    scrape_configs:
      - job_name: prometheus
        static_configs:
          - targets: ["localhost:9090"]
      - job_name: node-exporters
        static_configs:
          - targets:
              - "${local.service_ips.surrealdb}:9100"
              - "${local.service_ips.postgres}:9100"
              - "${local.service_ips.qvault}:9100"
              - "${local.service_ips.penpot}:9100"
              - "${local.service_ips.dns}:9100"
              - "${local.service_ips.dns2}:9100"
              - "${local.service_ips.ca}:9100"
              - "${local.service_ips.registry}:9100"
              - "${local.service_ips.gitea}:9100"
              - "${local.service_ips.verdaccio}:9100"
              - "node-exporter:9100"
      - job_name: postgres
        static_configs:
          - targets: ["${local.service_ips.postgres}:9187"]
      - job_name: coredns
        static_configs:
          - targets:
              - "${local.service_ips.dns}:9153"
              - "${local.service_ips.dns2}:9153"
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
  memory_mib       = 8192
  disk_gib         = 20
  bridge           = var.vhost_bridge
  static_ip        = "${local.service_ips.monitoring}${var.vhost_lan_cidr_suffix}"
  gateway          = var.vhost_gateway
  dns              = local.vm_dns
  firmware         = var.uefi_firmware
  nvram_template   = var.uefi_nvram_template
  vm_user          = var.vm_user
  ssh_public_key   = trimspace(file(pathexpand(var.ssh_public_key_path)))

  extra_files = concat(
    [
      { path = "/etc/monitoring/prometheus.yml", content = local.prometheus_config },
      { path = "/etc/monitoring/grafana-datasource.yml", content = local.grafana_datasource },
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
      volumes = [
        "/etc/monitoring/prometheus.yml:/etc/prometheus/prometheus.yml:Z",
        "prometheus-data:/prometheus",
      ]
    },
    {
      name  = "grafana"
      image = "docker.io/grafana/grafana:latest"
      ports = ["3001:3000"]
      environment = {
        GF_SECURITY_ADMIN_PASSWORD = random_password.grafana_admin.result
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
      depends_on = ["grafana", "prometheus"]
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
  memory_mib       = 4096
  disk_gib         = 15
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
  gitea_db_user = "gitea"
  gitea_db_pass = random_password.gitea_db.result

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
    export PGPASSWORD='${random_password.postgres.result}'
    export PGCONNECT_TIMEOUT=5

    # Wait for postgres to accept connections (bounded) before provisioning.
    tries=0
    until psql -h ${local.gitea_db_host} -U postgres -d postgres -c 'SELECT 1' >/dev/null 2>&1; do
      tries=$((tries + 1))
      if [ "$tries" -ge 30 ]; then
        echo "postgres at ${local.gitea_db_host} not ready after $tries attempts" >&2
        exit 1
      fi
      sleep 2
    done

    # Create or update the gitea role (always (re)set the password).
    psql -h ${local.gitea_db_host} -U postgres -d postgres -v ON_ERROR_STOP=1 \
      -c "CREATE ROLE ${local.gitea_db_user} LOGIN PASSWORD '${local.gitea_db_pass}'" \
      || psql -h ${local.gitea_db_host} -U postgres -d postgres -v ON_ERROR_STOP=1 \
      -c "ALTER ROLE ${local.gitea_db_user} WITH LOGIN PASSWORD '${local.gitea_db_pass}'"

    # Create the database if missing (CREATE DATABASE can't run in a DO block).
    if ! psql -h ${local.gitea_db_host} -U postgres -d postgres -tAc \
      "SELECT 1 FROM pg_database WHERE datname='${local.gitea_db_name}'" | grep -q 1; then
      psql -h ${local.gitea_db_host} -U postgres -d postgres -v ON_ERROR_STOP=1 \
        -c "CREATE DATABASE ${local.gitea_db_name} OWNER ${local.gitea_db_user}"
    fi

    # Ensure ownership is correct even if the db pre-existed.
    psql -h ${local.gitea_db_host} -U postgres -d postgres -v ON_ERROR_STOP=1 \
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
  disk_gib         = 30
  bridge           = var.vhost_bridge
  static_ip        = "${local.service_ips.gitea}${var.vhost_lan_cidr_suffix}"
  gateway          = var.vhost_gateway
  dns              = local.vm_dns
  firmware         = var.uefi_firmware
  nvram_template   = var.uefi_nvram_template
  vm_user          = var.vm_user
  ssh_public_key   = trimspace(file(pathexpand(var.ssh_public_key_path)))

  extra_files = concat(
    [
      { path = "/etc/infra/gitea/init-db.sh", content = local.gitea_init_script, permissions = "0755" },
    ],
    local.caddy_extra_files.gitea,
  )

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
      name       = "gitea"
      image      = "docker.io/gitea/gitea:1"
      ports      = ["2222:2222"]
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
        GITEA__security__INTERNAL_TOKEN = random_password.gitea_internal_token.result
        GITEA__security__SECRET_KEY     = random_password.gitea_secret_key.result
        GITEA__oauth2__JWT_SECRET       = random_password.gitea_jwt_secret.result
        GITEA__log__LEVEL               = "Info"
      }
      volumes = ["gitea-data:/data"]
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
