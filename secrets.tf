# ---------------------------------------------------------------------------
# Service secrets — SOURCED FROM OPENBAO (Phase 3 cutover)
#
# These 13 values are the operational credentials consumed across services.tf.
# They are NO LONGER generated here. OpenBao KV (kv-v2 at secret/) is the
# single source of truth; tofu reads them back via data "vault_kv_secret_v2".
#
#   seed path : secret/platform/services/<key>  (field "value")
#   read path : data.vault_kv_secret_v2.service["<key>"].data.value
#
# IMPORTANT caveats (read before editing):
#   * A tofu data source is recorded in state, so the VALUES still land in the
#     state file. OpenBao is the rotation point / operational SoT, not a way to
#     keep these out of state. Fully removing them from state requires the
#     per-service AppRole injection (Phase C) where tofu never reads the value.
#   * ROTATE by writing a NEW value to the KV path (bao kv put / tofu-managed
#     vault_kv_secret_v2 in a later phase) and running `tofu apply`. The config
#     re-renders and the container recreates.
#   * qvault_server_secret / qvault_session_secret are cryptographically bound
#     to the operator's passkey. DO NOT rotate them.
#   * postgres_password is the postgres superuser AND the tofu PG backend
#     password (PG_CONN_STR) AND, via services.tf, the gitea DB role. Rotating
#     it requires the manual DB-sync procedure (see note by local.secrets).
#   * The old random_password resources were removed via `tofu state rm` after
#     this file's apply produced a clean no-drift plan; values now live only in
#     OpenBao (and are re-read each plan).
# ---------------------------------------------------------------------------

locals {
  # Map every operational secret to its OpenBao KV path key.
  # (postgres note: rotating this value breaks PG_CONN_STR + the gitea DB role;
  #  sync the DB first, then rotate, in one maintenance window.)
  openbao_service_secret_keys = [
    "surrealdb_root_password",
    "postgres_password",
    "qvault_session_secret",
    "qvault_server_secret",
    "penpot_secret_key",
    "penpot_postgres_password",
    "grafana_admin_password",
    "gitea_db_password",
    "gitea_internal_token",
    "gitea_secret_key",
    "gitea_jwt_secret",
    "redis_password",
    "ntfy_alert_topic",
    "tofu_state_password",
  ]

  # Full secret objects read straight from OpenBao. Every field on the KV path
  # (value, username, plus any future field) is available verbatim. NO usernames
  # or other secret material are hardcoded anywhere in tofu — they live only in
  # OpenBao and are read back here.
  secrets = {
    for k in local.openbao_service_secret_keys :
    k => data.vault_kv_secret_v2.service[k].data
  }

  # Flat value-only map. Keep the KEYS identical to the historical output
  # "secrets" shape so nothing downstream changes name. Reads value field only.
  secrets_values = {
    for k in local.openbao_service_secret_keys :
    k => data.vault_kv_secret_v2.service[k].data["value"]
  }

  # Username map read from OpenBao. Credentials with no concept of a username
  # (api tokens, app keys, redis AUTH) have username = "" in OpenBao; consumers
  # that genuinely need a username only reference keys that have a non-empty
  # one. Empty string here is the stored "no username" value, not a hardcoded
  # default — it comes from the OpenBao read.
  secret_usernames = {
    for k in local.openbao_service_secret_keys :
    k => lookup(data.vault_kv_secret_v2.service[k].data, "username", "")
  }
}

# kv-v2 is mounted at secret/ on the main cluster; paths here are sub-paths
# under it (vault provider appends data/ internally for kv-v2).
data "vault_kv_secret_v2" "service" {
  for_each = toset(local.openbao_service_secret_keys)
  mount    = "secret"
  name     = "platform/services/${each.key}"
}
