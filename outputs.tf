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
    dns-lb     = module.dns_lb.ipv4
    dns1       = module.dns["dns1"].ipv4
    dns2       = module.dns["dns2"].ipv4
    ca         = module.ca.ipv4
    registry   = module.registry.ipv4
    # gitea is now active-active behind gitea-lb: gitea.lab.internal (a CNAME to
    # gitea-lb) is the stable client-facing name; the two backends are listed
    # individually for ops/diagnostics.
    gitea-lb        = module.gitea_lb.ipv4
    gitea-1         = module.gitea["gitea-1"].ipv4
    gitea-2         = module.gitea["gitea-2"].ipv4
    verdaccio       = module.verdaccio.ipv4
    nfs             = module.nfs.ipv4
    redis           = module.redis.ipv4
    openbao         = module.openbao.ipv4
    openbao-transit = module.openbao_transit.ipv4
    gitea-runner-1  = module.gitea_runner["gitea-runner-1"].ipv4
    gitea-runner-2  = module.gitea_runner["gitea-runner-2"].ipv4
  }
}

output "root_ca_pem" {
  description = "Root CA certificate to install into client trust stores (e.g. /etc/pki/ca-trust/source/anchors/ + update-ca-trust on Fedora)"
  value       = local.root_ca_cert_pem
}

# ntfy alert topic + URL: subscribe the ntfy phone app to
# "https://ntfy.lab.internal/<ntfy_alert_topic>" to receive downt alerts.
output "ntfy_alert_topic" {
  description = "Random ntfy topic Alertmanager posts downtime alerts to (subscribe the phone app to https://ntfy.lab.internal/<this>)"
  value       = local.secrets_values.ntfy_alert_topic
  sensitive   = true
}

output "service_urls" {
  description = "HTTPS URLs for the web services (requires DNS pointed at the infra VM and the root CA trusted; nfs is not HTTP -- listed as its NFSv4 endpoint for completeness; dns/dns2 are the RFC 8484 DoH endpoints, not web UIs)"
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
    # Phone-app subscribe URL: append the ntfy_alert_topic from outputs/secrets.
    ntfy = "https://ntfy.${local.internal_domain}/<ntfy_alert_topic>"
    nfs  = "nfs://nfs.${local.internal_domain}/gitea"
    # rediss:// = Redis over TLS (self-signed server cert; pin it or skip
    # verification on the LAN). Password via `tofu output -json secrets`.
    redis = "rediss://redis.${local.internal_domain}:6379"
    dns   = "https://dns.${local.internal_domain}/dns-query"
    dns2  = "https://dns2.${local.internal_domain}/dns-query"
    # OpenBao API/UI (caddy-fronted TLS; auto-unseals via the transit provider).
    openbao = "https://openbao.${local.internal_domain}"
  }
}

# Convenience output for state recovery: the postgres password is also the
# tofu state backend password (PG_CONN_STR). Sensitive so it's not printed
# in plain text by `tofu output` without `-raw`.
output "postgres_password" {
  description = "Postgres superuser password (also the tofu state backend password — used in PG_CONN_STR)"
  value       = local.secrets_values.postgres_password
  sensitive   = true
}

output "secrets" {
  description = "Service credentials (sourced from OpenBao KV; retrieve with: tofu output -json secrets)"
  sensitive   = true
  value = {
    surrealdb_root_password  = local.secrets_values.surrealdb_root_password
    postgres_password        = local.secrets_values.postgres_password
    qvault_session_secret    = local.secrets_values.qvault_session_secret
    qvault_server_secret     = local.secrets_values.qvault_server_secret
    penpot_secret_key        = local.secrets_values.penpot_secret_key
    penpot_postgres_password = local.secrets_values.penpot_postgres_password
    grafana_admin_password   = local.secrets_values.grafana_admin_password
    gitea_db_password        = local.secrets_values.gitea_db_password
    gitea_internal_token     = local.secrets_values.gitea_internal_token
    gitea_secret_key         = local.secrets_values.gitea_secret_key
    gitea_jwt_secret         = local.secrets_values.gitea_jwt_secret
    ntfy_alert_topic         = local.secrets_values.ntfy_alert_topic
    redis_password           = local.secrets_values.redis_password
  }
}

# Usernames for the same credentials, also sourced from OpenBao (not hardcoded).
# "" means the credential has no username (api token / app key / redis AUTH).
output "secrets_usernames" {
  description = "Usernames for the service credentials, sourced from OpenBao (empty string = no username). Retrieve with: tofu output -json secrets_usernames"
  sensitive   = true
  value       = local.secret_usernames
}

output "openbao_ui_login" {
  description = "Sign-in details for the OpenBao UI. Password via 'tofu output openbao_admin_bootstrap_password' (sensitive)."
  value = {
    url      = "https://openbao.${local.internal_domain}/ui"
    method   = "userpass"
    path     = vault_auth_backend.userpass.path
    username = var.openbao_admin_username
  }
}

output "openbao_admin_bootstrap_password" {
  description = "FIRST-USE bootstrap password for the OpenBao operator. Rotate via UI immediately after first login."
  value       = random_password.openbao_admin_bootstrap.result
  sensitive   = true
}
