# OpenBao follow-ups

Deferred work items from the OpenBao rollout (Phase B cutover + state rebuild),
2026-09-03. Each is independent; pick them up in any order. None blocks the
current steady-state (state is on the pg backend with a new passphrase and a
dedicated `tofu` role password; service secrets are read from OpenBao KV).

---

## 1. Phase D — Transit seal fragility on restart (highest risk)

**Problem.** The transit cluster (`openbao-transit-vm`, .28) uses a **shamir
recovery seal**, which means it **re-seals on every container/VM restart**.
Main `openbao` (.27) auto-unseals **via** transit, so a transit restart
cascades: transit comes up sealed → main's auto-unseal fails → main crash-loops
(seen repeatedly during the state rebuild, each time requiring a manual
`bao operator unseal` ×3 on .28 with recovery keys).

Any event that restarts the transit container — a `config_sync` quadlet change,
an OS/package auto-update reboot, the quadlet watchdog — currently takes the
whole secrets stack down until someone unseals transit by hand.

**Options.**

- **Auto-unseal the transit seal too.** OpenBao supports nesting seal types.
  Give transit a lighter-touch unseal so it can come up unattended. Candidates:
  - **PKCS#11 / SoftHSM** on the transit VM (key held on the host, not in KV).
  - A **second transit** (two-node auto-unseal ring) — heavier, still a
    bootstrap problem at the bottom.
  - **cloud-kms**-style — not applicable on-prem.
- **Accept manual, but make it one command.** Add
  `scripts/openbao-unseal-transit.sh` that reads 3 recovery keys (from your
  password manager, prompted) and unseals + restarts main. Cheap, still manual.
- **Watchdog guard.** Teach the quadlet watchdog to *skip* restarting
  `openbao`/`openbao-transit` containers (treat them as "operator-managed") so
  an unrelated quadlet refresh never bounces the seal.

**Decision needed:** which unseal model for the bottom of the chain, balancing
attendance vs on-host-key exposure. Until then, treat transit restarts as
planned-maintenance events.

---

## 2. Phase C — Per-service AppRole + consumer migration

**Goal.** Stop storing service secret *values* in tofu state at all. Today
tofu reads every value from KV at plan time (`data "vault_kv_secret_v2"`), so
each value transits plan/state (encrypted, but present).

**Shape.**

- Issue one **AppRole** per service (SurrealDB, Postgres, Gitea, Penpot,
  Grafana, …) with a policy scoped to exactly the `secret/data/platform/
  services/<svc>` paths it needs.
- Services **pull at runtime** (via agent / a small fetch in their quadlet
  `ExecStartPre`) instead of receiving the value as an env var rendered by
  tofu/cloud-init.
- tofu then only manages the AppRole + policy + role-id/secret-id plumbing —
  never the secret value itself.

**Pre-req / dependency:** container reload signalling is already sorted
(`modules/vm/sync.sh.tmpl`), so a secret change can bounce just the affected
container. The migration is per-service and incremental — one AppRole at a
time, lowest-risk services first (grafana admin, ntfy topic), databases last.

---

## 3. Selective app-key rotation (not qvault / DB passwords)

Rotate only **regenerable** app keys via a KV `put` + `tofu apply`:

- Safe to rotate: gitea `secret_key` / `internal_token` / `jwt_secret` (forces
  re-login), grafana admin password (change via UI first, then sync KV), ntfy
  alert topic.
- **Do NOT rotate without a migration path:**
  - `qvault_server_secret` / `qvault_session_secret` — cryptographically tied
    to your passkey; changing them strands the existing passkey.
  - DB passwords (`postgres`, `surrealdb_root`, `gitea_db`, `penpot_postgres`,
    `redis`) — the value in KV and the live DB role must change together;
    rotating KV alone strands state / breaks live connections.
- `tofu_state_password` — rotate only alongside `ALTER ROLE tofu` (see
  `scripts/rebuild-state.sh` Step 2 for the sync pattern).

---

## 4. User-side hygiene (not code changes here)

- **OpenBao UI sign-in:** sign in as `chris` (userpass) and change the
  bootstrap password via the UI. Keep the **root token** as break-glass (do not
  revoke it — the vault provider needs *a* token on every plan because the KV
  data sources are read at plan time).
- **GitHub cached-leak purge:** open a GitHub Support request to purge the
  cached view of the commit that previously contained a leaked secret, even
  after the source branch was rewritten.

---

## Reference

- Transit unseal keys / recovery keys: held out-of-band (password manager).
- Root tokens (main `s.OZTQ…`, transit `s.VpYD…`): custody in your password
  manager; break-glass only.
- `scripts/rebuild-state.sh` — the state-rebuild procedure (drop/recreate
  `tofu_state`, local-backend, re-import, migrate to pg) and the only safe
  passphrase-rotation path.
