# Plan: Podman Quadlet Watchdog (self-healing for stopped containers)

## Problem

Quadlet-managed containers are started by systemd at boot (`WantedBy=multi-user.target`)
and have `Restart=always` in their generated `.container` files. Two gaps remain:

1. **`RefuseManualStop=yes` only guards the systemd stop path.** A container can
   still end up stopped **via podman directly**, which systemd never "saw" as a
   stop, so `Restart=always` does NOT bring it back:
   - `podman stop <name>` (operator on the host, bypassing systemd)
   - the daily **`podman auto-update` timer** (AutoUpdate=registry on every quadlet):
     it stops + recreates containers; if the recreate/race fails, the unit is left
     inactive.
   - OOM or a crash loop that exhausts `StartLimitBurst`, leaving the unit `failed`/
     `inactive` rather than auto-restarting forever.
2. When a container is stopped via podman, its generated systemd unit sits
   **inactive (dead)** — the service appears "not running" but nothing re-starts it.

Goal: a tiny watchdog that, on a timer, ensures every **long-running** quadlet
container's systemd unit is `active`, and if not, brings it back — explicitly
accounting for `RefuseManualStop=yes`.

## What `RefuseManualStop` does and does not block

`RefuseManualStop=yes` is set in the quadlet `[Unit]` section. Consequences:

- **Blocked:** `systemctl stop <name>.service` → systemd refuses ("Operation refused").
- **Blocked (the trap):** `systemctl restart <name>.service` on a unit whose
  `RefuseManualStop` applies can ALSO be refused in some stop paths, because a restart
  is stop+start and the stop gate fires.
- **NOT blocked:** direct podman operations — `podman stop <name>` / `podman start <name>`.
  These go to the podman runtime, not PID 1.
- **NOT blocked:** `systemctl start <name>.service` on an *inactive* unit (start is not
  a stop, so the gate does not fire). This is the key usable path.

So the watchdog's recovery ladder, per stopped/container-less unit, is:

```
if unit active -> nothing
else
  1. systemctl start <name>.service        # START is allowed over RefuseManualStop (only STOP is refused);
                                           # also retries a `failed` unit after the start-limit backoff
  2. if that fails -> podman start <name>  # start the EXISTING (stopped) container in place —
                                           # same named volume, same podman IP, NO recreation
  3. if both fail -> log `-p err` for manual intervention; do NOT touch/remove the container
```

**The watchdog never runs `podman rm`/`recreate`.** An earlier draft included a
`podman rm -f <name>` recreate rung — removed because forced container recreation is a
data/state-loss risk for stateful services and breaks dependents that cached the
container's podman IP (this exact situation caused the penpot 502). Start-only
recovery preserves the named volume and the container's stable identity, which is the
safe operation here. A hard-failed unit that start can't revive is left intact and a
loud journal error alerts the operator.

## Scope: which containers the watchdog watches

- **Include:** every container in `var.containers` with `oneshot = false`
  (i.e. long-running `Restart=always` services).
- **Exclude:** `oneshot = true` bootstrap sidecars — after they run their unit is
  correctly `inactive (dead)` and must NOT be restarted. The per-VM list is
  filtered in HCL so the rendered watchdog only enumerates non-oneshot names.

## Design

Add a single, self-contained watchdog bit to the `vm` module, delivered through
**both** existing paths (cloud-init first boot + zero-downtime live sync), gated by a
new variable `watchdog` (default `true`). No new top-level resources; it reuses the
existing `extra_files`/`extra_runcmd` plumbing by *appending to what the module already
renders* — so it lands on every VM fleet-wide with `tofu apply`, no VM reboots.

### Files (rendered per-VM)

1. `/usr/local/sbin/quadlet-watchdog.sh` (0755)
   - Arg: space-separated list of long-running container names for this VM
     (rendered by HCL from `[for c in var.containers : c.name if !c.oneshot]`).
   - For each name: if `systemctl is-active --quiet <name>.service` fails, run the
     recovery ladder above; log each recovery to systemd-journald via `logger -t
     quadlet-watchdog`.
   - Idempotent; fast no-op when everything is active; `set -uo pipefail` (NO `-e`:
     must continue through individual unit failures and never abort the whole run).

2. `/etc/systemd/system/quadlet-watchdog.service` (0644)
   - `Type=oneshot`, `ExecStart=/usr/local/sbin/quadlet-watchdog.sh <names>`.
   - No `[Install]` block (triggered solely by the timer; not WantedBy a target).

3. `/etc/systemd/system/quadlet-watchdog.timer` (0644)
   - `[Timer] OnBootSec=60s OnUnitActiveSec=30s Persistent=true`
   - `[Install] WantedBy=timers.target`
   - Cadence 30s ≈ the penpot 502 window we just hit; `Persistent=true` catches up
     after any timer downtime.

### Module wiring (single source of truth stays in HCL)

The container names + oneshot flags already live in `var.containers`. The watchdog
only *consumes* them; it does not duplicate the container list anywhere.

- `modules/vm/variables.tf`
  - add `variable "watchdog" { type = bool; default = true }` — per-VM opt-out.

- `modules/vm/main.tf`
  - build the watchdog file contents in `locals` (script, service, timer), gated on
    `var.watchdog && length([for c in var.containers : c if !c.oneshot]) > 0` (skip on
    VMs with no long-running containers).
  - append them to the rendered `extra_files` passed to BOTH the cloud-init template
    and the sync path, and append the activation `extra_runcmd` entries
    (`systemctl daemon-reload`, `systemctl enable --now quadlet-watchdog.timer`).
  - Because `extra_files`/`extra_runcmd` feed `config_sync`'s `triggers_replace`
    (sha256 of each), adding the watchdog changes those hashes → the **live sync
    fires** on running VMs and pushes the 3 files + enables the timer, with zero
    reboots. Cloud-init path covers fresh boots.

- `modules/vm/sync.sh.tmpl`
  - the generic phase-1 extra_files writer already syncs `/usr/local/sbin/*` and
    `/etc/systemd/system/*` if present in `extra_files`; add a dedicated post-step:
    if the watchdog timer file changed (or is being enabled for the first time on an
    already-running VM), run `systemctl daemon-reload` + `enable --now
    quadlet-watchdog.timer`. This is appended to the module-rendered `extra_runcmd`
    used by the sync path, so the same idempotent line runs live.

### Why a timer, not a systemd `Type=notify`/path unit or in-unit `Restart`

- A timer is the smallest reliable loop; `OnUnitActiveSec=30s` re-arms after each run.
- `Restart=always` already handles in-container crashes; it cannot handle the
  podman-level stop gap (the actual reported bug). The watchdog exists specifically
  for that gap, so a periodic external check is the right tool, not another in-unit
  directive.

## Acceptance criteria

- On a VM with long-running containers: after apply, `systemctl list-timers
  quadlet-watchdog.timer` shows it armed; `systemctl cat quadlet-watchdog.service`
  lists the VM's non-oneshot container names.
- `podman stop <non-oneshot-container>` (bypass systemd) → within ~30s the watchdog
  logs a recovery and the container is running again; `systemctl is-active` flips back
  to active.
- Oneshot sidecars are never restarted by the watchdog (verify an completed oneshot
  stays inactive).
- `systemctl daemon-reload` + repeat runs are no-op when all containers are up
  (no flapping, no journal spam beyond the recovery events).
- Oneshot/absent-container VMs get no watchdog files and no errors.

## Risk / notes

- The watchdog only STARTS; it never stops or restarts a healthy container (no
  service flapping).
- Requires sudo on the VM (script runs as root via the systemd unit — no privilege
  problem).
- The `RefuseManualStop` start-vs-stop nuance is handled by preferring
  `systemctl start` (allowed over the gate) and dropping to `podman start` / recreate
  when the unit is `failed`. Documented inline in the script for future maintainers.
- `podman auto-update` overlap: brief windows where the timer and watchdog race are
  self-correcting — the watchdog simply ensures the end state is "active".
