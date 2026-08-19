#!/usr/bin/env bash
#
# rerender-cloudinit-fleet.sh
#
# Purpose
# -------
# After a `tofu apply` that *replaced* every VM's cloud-init volume (e.g. the
# auto-updates rollout), the new user-data only lands on disk. cloud-init on
# the *running* VM never notices, because its per-instance marker is keyed on
# meta_data.instance-id — and modules/vm/main.tf sets
#   instance-id = var.name
# which hasn't changed. So the VM keeps booted-from-the-old-ISO semantics
# until something forces a re-render.
#
# This script does the forcing, for every VM in the fleet, serially so we
# never take down two dependencies of the same service at once:
#   1. ssh in, `sudo cloud-init clean --logs`  (clear the per-instance cache
#      and prior logs so next boot is treated as a new instance)
#   2. `sudo systemctl reboot`                  (clean reboot; cloud-init runs
#      full `init` + `modules-*` on the way up against the NEW ISO)
#   3. wait until SSH is back and `cloud-init status` reports `done`
#   4. verify the two auto-update timers rendered by the template are
#      enabled + active
#   5. print a per-VM pass/fail line, then continue to the next VM
#
# Run AFTER `tofu apply` has replaced the cloud-init volumes. Running it
# before just reboots each VM once for no gain.
#
# Do we need to do this for each machine?
# Yes — *this time only*, because we changed user-data *after* initial
# provisioning, and instance-id is name-keyed so tofu can't force a
# cloud-init re-render on its own. (The alternative — changing instance-id —
# would rebuild each root disk, which is what the `-replace` on the volume
# already does the cheap way.) For all future VM *rebuilds* the template
# renders fresh automatically; this script is only for "cloud-init content
# changed, VMs stayed".
#
# Usage:  bash scripts/rerender-cloudinit-fleet.sh           # all 13 VMs
#         bash scripts/rerender-cloudinit-fleet.sh gitea-vm  # one VM only
#
set -u
SSH_KEY="${SSH_KEY:-$HOME/.ssh/fedora_deploy_ed25519}"
SSH_USER="${SSH_USER:-fedora}"
# StrictHostKeyChecking=accept-new would still refuse on a *changed* key —
# and the cloud-init-volume replace regenerates host keys on every VM, so we
# must wipe the known_hosts entry before rebooting (done per-VM below), then
# accept-new admits the new key on first contact. ConnectionAttempts handles
# the normal "sshd not quite up yet" race right after reboot.
SSH_OPTS=(
  -o StrictHostKeyChecking=accept-new
  -o ConnectTimeout=8
  -o ConnectionAttempts=3
  -o BatchMode=yes
  -i "$SSH_KEY"
)
DOMAIN="lab.internal"

# Full fleet, by DNS A-record short name (see local.service_ips). In
# boot-dependency-tolerant order: dns first so name resolution never breaks
# mid-run; nfs before its client gitea.
ALL_VMS=(
  dns dns2
  ca registry
  surrealdb postgres qvault penpot monitoring aspire
  nfs gitea verdaccio
)

# last octet of each VM's static IP (192.168.70.<octet>), keyed by short name
# — parallel to ALL_VMS. Used to probe ssh by raw IP during the post-reboot
# wait so a stale hostname-keyed known_hosts entry can't wedge recovery.
declare -A VM_IP=(
  [surrealdb]=10 [postgres]=11 [qvault]=12 [penpot]=13 [monitoring]=14
  [aspire]=15 [dns]=16 [registry]=17 [ca]=18 [dns2]=19
  [gitea]=20 [verdaccio]=21 [nfs]=22
)

if [ $# -gt 0 ]; then
  VMS=("$@")
else
  VMS=("${ALL_VMS[@]}")
fi

pass=0
fail=0
results=()

wait_for_cloudinit() {
  local host=$1
  # Two conditions, each with their own timeout:
  #   a) ssh answers once more after the reboot
  #   b) cloud-init finishes (status=done), up to 180s after that
  # 240s here: a reboot after `cloud-init clean --logs` re-runs the full
  # module pipeline against the fresh ISO (including container pulls if the
  # template changed images), so first successful ssh can legitimately take
  # well over a minute.
  local deadline=$((SECONDS + 240))
  local up=1
  # Don't probe immediately — the rebooting host can accept a TCP connection
  # in early userspace and then drop it, which counts as "back up" before
  # sshd is really ready. Give it a solid head start first.
  sleep 15
  while [ $SECONDS -lt $deadline ]; do
    if ssh "${SSH_OPTS[@]}" "$SSH_USER@$host" true 2>/dev/null; then
      up=0
      break
    fi
    sleep 3
  done
  if [ $up -ne 0 ]; then
    return 1   # host never came back on ssh
  fi
  deadline=$((SECONDS + 180))
  while [ $SECONDS -lt $deadline ]; do
    if ssh "${SSH_OPTS[@]}" "$SSH_USER@$host" \
         'test "$(cloud-init status 2>/dev/null)" = "status: done"' 2>/dev/null; then
      return 0
    fi
    sleep 5
  done
  return 2     # up, but cloud-init never reached done
}

for vm in "${VMS[@]}"; do
  host="${vm}.${DOMAIN}"
  octet="${VM_IP[$vm]:-}"
  ip=""
  if [ -n "$octet" ]; then
    ip="192.168.70.${octet}"
  fi
  printf '==> %s (%s)\n' "$host" "${ip:-no-ip}"

  # 1) drop stale known_hosts entries — BOTH the FQDN and the raw IP, since
  #    earlier connections (and the verification probes below) may have
  #    registered either form. The cloud-init volume replace regenerates the
  #    VM's host keys, and any leftover entry makes ssh fail strict checking
  #    on the first post-reboot connection.
  ssh-keygen -R "$host" >/dev/null 2>&1 || true
  if [ -n "$ip" ]; then
    ssh-keygen -R "$ip" >/dev/null 2>&1 || true
  fi

  # 2) clean cloud-init state + logs, then reboot. Connect by FQDN here —
  #    the IP probe below is only for post-reboot recovery where the FQDN's
  #    resolver path might briefly depend on the very DNS VM we're rebooting.
  #
  # LIMITATION: instance-id is name-keyed (modules/vm/main.tf:21) so the
  # meta-data never changes between applies. cloud-init's datasource sees the
  # same instance-id from the (new) seed and *still* skips per-instance
  # modules. For a *config-changing* cloud-init rollout (e.g. adding a new
  # container), a one-time manual step is needed on each VM:
  #   sudo cloud-init clean --logs && \
  #   sudo rm -rf /var/lib/cloud/instance /var/lib/cloud/instances/* && \
  #   sudo systemctl reboot
  # (the plain-clean here is enough for routine refreshes like.timer checks
  # after the auto-updates rollout, since those just need the boot to
  # *re-execute* cloud-init, not to forget it ever ran).
  if ! ssh "${SSH_OPTS[@]}" "$SSH_USER@$host" \
       'sudo cloud-init clean --logs >/dev/null 2>&1 && sudo systemctl reboot' 2>/dev/null; then
    # ssh drops the moment systemctl reboot kicks in; non-zero exit is expected.
    :
  fi

  # 3) wait for it to come back with cloud-init done. Probe by raw IP so we
  #    never end up waiting on a resolver that was itself just rebooted (the
  #    dns/dns2 VMs are the resolvers for every name in lab.internal).
  if [ -z "$ip" ]; then
    printf '    FAIL  (no IP known for %s — add it to VM_IP)\n' "$vm"
    results+=("$host: fail-no-ip-map")
    fail=$((fail + 1))
    continue
  fi
  wait_for_cloudinit "$ip"
  rc=$?
  if [ $rc -eq 1 ]; then
    printf '    FAIL  (ssh never recovered after reboot)\n'
    results+=("$host: fail-no-ssh")
    fail=$((fail + 1))
    continue
  elif [ $rc -eq 2 ]; then
    printf '    FAIL  (cloud-init did not reach status=done within 180s)\n'
    results+=("$host: fail-cloudinit-stuck")
    fail=$((fail + 1))
    continue
  fi

  # 4) verify the timers the template now renders (by IP, same reason as #3)
  out=$(ssh "${SSH_OPTS[@]}" "$SSH_USER@$ip" \
    'systemctl is-enabled dnf5-automatic.timer podman-auto-update.timer; \
     systemctl is-active  dnf5-automatic.timer podman-auto-update.timer' 2>/dev/null)
  en1=$(sed -n 1p <<<"$out"); en2=$(sed -n 2p <<<"$out")
  ac1=$(sed -n 3p <<<"$out"); ac2=$(sed -n 4p <<<"$out")

  if [ "$en1" = enabled ] && [ "$en2" = enabled ] && \
     { [ "$ac1" = "active" ] || [ "$ac1" = "active (waiting)" ]; } && \
     { [ "$ac2" = "active" ] || [ "$ac2" = "active (waiting)" ]; }; then
    printf '    OK    dnf5-automatic: %s/%s   podman-auto-update: %s/%s\n' \
      "$en1" "$ac1" "$en2" "$ac2"
    results+=("$host: ok")
    pass=$((pass + 1))
  else
    printf '    FAIL  dnf5-automatic: %s/%s   podman-auto-update: %s/%s\n' \
      "$en1" "$ac1" "$en2" "$ac2"
    results+=("$host: fail-timers")
    fail=$((fail + 1))
  fi
done

echo
echo "---- summary ----"
for r in "${results[@]}"; do
  echo "  $r"
done
echo "passed: $pass   failed: $fail"
exit $(( fail > 0 ? 1 : 0 ))
