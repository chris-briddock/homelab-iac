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
