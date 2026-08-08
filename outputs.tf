output "vm_ips" {
  description = "IPv4 addresses assigned to each VM (available once cloud-init completes and DHCP hands out a lease)"
  value       = { for k, v in module.vm : k => v.ipv4 }
}

output "service_ips" {
  description = "IPv4 addresses of the real services on the vhost (bridged LAN, DHCP-assigned)"
  value = {
    surrealdb  = module.surrealdb.ipv4
    postgres   = module.postgres.ipv4
    qvault     = module.qvault.ipv4
    penpot     = module.penpot.ipv4
    monitoring = module.monitoring.ipv4
    aspire     = module.aspire.ipv4
    dns        = module.dns["dns"].ipv4
    dns2       = module.dns["dns2"].ipv4
    ca         = module.ca.ipv4
    registry   = module.registry.ipv4
    gitea      = module.gitea.ipv4
    verdaccio  = module.verdaccio.ipv4
  }
}

output "root_ca_pem" {
  description = "Root CA certificate to install into client trust stores (e.g. /etc/pki/ca-trust/source/anchors/ + update-ca-trust on Fedora)"
  value       = local.root_ca_cert_pem
}

output "service_urls" {
  description = "HTTPS URLs for the web services (requires DNS pointed at the infra VM and the root CA trusted)"
  value = {
    qvault     = "https://qvault.${local.internal_domain}"
    penpot     = "https://penpot.${local.internal_domain}"
    grafana    = "https://grafana.${local.internal_domain}"
    prometheus = "https://prometheus.${local.internal_domain}"
    aspire     = "https://aspire.${local.internal_domain}"
    registry   = "https://registry.${local.internal_domain}"
    gitea      = "https://gitea.${local.internal_domain}"
    verdaccio  = "https://verdaccio.${local.internal_domain}"
    ca         = "https://ca.${local.internal_domain}:9000"
  }
}

output "secrets" {
  description = "Generated credentials for the real services (retrieve with: tofu output -json secrets)"
  sensitive   = true
  value = {
    surrealdb_root_password  = random_password.surrealdb_root.result
    postgres_password        = random_password.postgres.result
    qvault_session_secret    = random_password.qvault_session_secret.result
    qvault_server_secret     = random_password.qvault_server_secret.result
    penpot_secret_key        = random_password.penpot_secret_key.result
    penpot_postgres_password = random_password.penpot_postgres.result
    grafana_admin_password   = random_password.grafana_admin.result
    gitea_db_password        = random_password.gitea_db.result
    gitea_internal_token     = random_password.gitea_internal_token.result
    gitea_secret_key         = random_password.gitea_secret_key.result
    gitea_jwt_secret         = random_password.gitea_jwt_secret.result
  }
}
