# ---------------------------------------------------------------------------
# OpenBao — auth methods, policies, UI users
#
# Managed via the upstream `vault` provider (OpenBao is an MPL-2.0 fork fully
# API-compatible with Vault 1.14+). This file owns:
#   - the userpass auth backend
#   - the operator ACL policy
#   - the initial admin user (you, signing in through the UI)
#
# What this file does NOT own:
#   - The bootstrap root token / recovery shares. Those continue to live in
#     KV at secret/platform/openbao/bootstrap as break-glass custody.
#   - Per-service KV entries (Phase B) and AppRole/consumer auth (Phase C).
#     Those land in their own files when they're ready.
#
# First-apply story: generate a random bootstrap password, create the
# userpass user with that password + operator policy, expose the password
# via a sensitive tofu output. Operator signs in once, changes it via UI,
# and treats the tofu-side value as irrelevant thereafter (hence no keepers
# rotation rig on random_password.openbao_admin_bootstrap).
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# Bootstrap password for the Initial User
# ---------------------------------------------------------------------------
resource "random_password" "openbao_admin_bootstrap" {
  length  = 24
  special = true
  # Intentionally NO `keepers` — this is one-use. Rotate via UI by editing
  # your own userpass user after first login. Keeping `keepers` absent here
  # means `local.secret_rotation` bumps in secrets.tf do NOT touch this
  # password (which would be wrong: your real password is by then changed
  # via UI, and this state copy is stale on purpose).
}

# ---------------------------------------------------------------------------
# userpass auth backend
# ---------------------------------------------------------------------------
resource "vault_auth_backend" "userpass" {
  type        = "userpass"
  path        = "userpass"
  description = "Human operators UI sign-in"

  tune {
    default_lease_ttl = "768h" # 32 days
    max_lease_ttl     = "768h"
    # audit_non_hmac_response_keys and listing_visibility defaults are fine.
  }
}

# ---------------------------------------------------------------------------
# Operator ACL
#
# Broad within secret/ + read-only on auth/policies/mounts/health for UI
# navigation. NO sudo paths. NO sys/policy write. NO sys/auth write.
# NO sys/mounts write. NO transit/* ops. Break-glass remains: root token via
# recovery keys, then any sudo work goes through that consciously.
# ---------------------------------------------------------------------------
resource "vault_policy" "operator" {
  name   = "operator"
  policy = <<-EOT
    # Browse + manage service secret trees
    path "secret/data/*"     { capabilities = ["create","read","update","delete","list"] }
    path "secret/metadata/*" { capabilities = ["read","list","delete"] }

    # Read auth/policies/mounts for UI navigation
    path "sys/auth"              { capabilities = ["read","list"] }
    path "sys/auth/*"            { capabilities = ["read"] }
    path "sys/policies/acl"      { capabilities = ["read","list"] }
    path "sys/policies/acl/*"    { capabilities = ["read"] }
    path "sys/mounts"            { capabilities = ["read","list"] }
    path "sys/mounts/*"          { capabilities = ["read"] }

    # Status/info
    path "sys/health"        { capabilities = ["read"] }
    path "sys/seal-status"   { capabilities = ["read"] }
    path "sys/host-info"     { capabilities = ["read"] }
    path "sys/audit"         { capabilities = ["read","list"] }

    # Self-token management
    path "auth/token/lookup-self"       { capabilities = ["read"] }
    path "auth/token/renew-self"        { capabilities = ["update"] }
    path "auth/token/revoke-self"       { capabilities = ["update"] }
    path "auth/token/roles"             { capabilities = ["read","list"] }

    # UI helper endpoints (the sidebar mounts/namespaces panels)
    path "sys/internal/ui/mounts"       { capabilities = ["read","list"] }
    path "sys/internal/ui/mounts/*"     { capabilities = ["read"] }
    path "sys/internal/ui/namespaces"   { capabilities = ["read","list"] }
    path "sys/internal/ui/resultant-acl"{ capabilities = ["read"] }
  EOT
}

# ---------------------------------------------------------------------------
# Admin user
#
# vault_generic_endpoint is used because there is no first-class
# vault_userpass_user resource in vault provider v4 — the generic endpoint
# gives complete control and matches the upstream API exactly. The
# token_policies field is the modern replacement for the legacy `policies`.
# ---------------------------------------------------------------------------
resource "vault_generic_endpoint" "admin_user" {
  depends_on           = [vault_auth_backend.userpass, vault_policy.operator]
  path                 = "auth/${vault_auth_backend.userpass.path}/users/${var.openbao_admin_username}"
  ignore_absent_fields = true
  disable_read         = false
  disable_delete       = false

  data_json = jsonencode({
    password       = random_password.openbao_admin_bootstrap.result
    token_policies = ["default", vault_policy.operator.name]
  })

  # Mask the password write_body in plan/apply output. The token_policies
  # field is not secret but data_json contains the password, so vault
  # provider already redacts the entire blob from logs.
}
