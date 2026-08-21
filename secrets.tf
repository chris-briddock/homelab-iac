resource "random_password" "surrealdb_root" {
  length  = 32
  special = false
}

resource "random_password" "postgres" {
  length  = 32
  special = false
}

resource "random_password" "qvault_session_secret" {
  length  = 40
  special = false
}

resource "random_password" "qvault_server_secret" {
  length  = 40
  special = false
}

resource "random_password" "penpot_secret_key" {
  length  = 40
  special = false
}

resource "random_password" "penpot_postgres" {
  length  = 32
  special = false
}

resource "random_password" "grafana_admin" {
  length  = 24
  special = false
}

# Gitea (uses the shared standalone Postgres VM as its DB).
resource "random_password" "gitea_db" {
  length  = 32
  special = false
}

resource "random_password" "gitea_internal_token" {
  # Gitea requires an INTERNAL_TOKEN of decent length.
  length  = 64
  special = false
}

resource "random_password" "gitea_secret_key" {
  length  = 40
  special = false
}

resource "random_password" "gitea_jwt_secret" {
  length  = 48
  special = false
}

# Un-guessable ntfy alert topic (the "password" for who can see/post alerts
# on the monitoring VM's ntfy instance). The topic path is what carries the
# secret: ntfy has no auth in this setup, so anyone who can reach the topic
# name can read it -- keep this as long/random as the service passwords.
resource "random_password" "ntfy_alert_topic" {
  length  = 40
  special = false
}
