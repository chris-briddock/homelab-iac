terraform {
  required_version = ">= 1.7.0"

  # Remote state in the shared Postgres VM (dedicated tofu_state DB + tofu role).
  # Connection string is supplied via the PG_CONN_STR env var (never committed):
  #   export PG_CONN_STR="postgres://tofu:<pw>@<ip>:5432/<dbname>?sslmode=disable"
  # The pg backend gives state locking, so concurrent applies can't corrupt state.
  backend "pg" {
    schema_name = "tofu"
  }

  # Encrypt state + plan files at rest (they hold the root CA key and service
  # passwords). PBKDF2 derives a key from a passphrase supplied via env var:
  #   export TF_ENCRYPTION_PASSPHRASE="<strong passphrase>"
  encryption {
    key_provider "pbkdf2" "state" {
      passphrase = var.tf_encryption_passphrase
    }
    method "aes_gcm" "state" {
      keys = key_provider.pbkdf2.state
    }
    state {
      method   = method.aes_gcm.state
      enforced = true
    }
    plan {
      method   = method.aes_gcm.state
      enforced = true
    }
  }

  required_providers {
    libvirt = {
      source  = "dmacvicar/libvirt"
      version = "~> 0.9.8"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
  }
}
