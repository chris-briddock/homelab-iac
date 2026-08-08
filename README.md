# Home Lab Infrastructure As Code

OpenTofu configuration that provisions KVM/libvirt VMs and runs their workloads as
podman containers (via quadlet), all bootstrapped through cloud-init on first boot.
No Ansible or remote-exec step — everything a VM needs ships in its cloud-init ISO.

## Layout

- `versions.tf`, `providers.tf` — provider requirements and libvirt connections.
- `variables.tf` — inputs: base image URL, SSH key path, vhost connection details,
  the local `vms` map, etc.
- `main.tf` — local libvirt pool/base image + `module "vm"` for_each over `var.vms`
  (currently unused; local test VMs go here).
- `infra.tf` — DNS (CoreDNS), CA (step-ca), and the docker.io registry cache, on the
  `vhost` provider.
- `services.tf` — the real service VMs on the `vhost` provider: SurrealDB, Postgres,
  qvault, Penpot, Prometheus/Grafana, the Aspire OTLP dashboard, Gitea (self-hosted
  git, source mirrors for npm packages), and Verdaccio (local npm registry). Also
  defines `service_ips` (the static IP plan) and the shared Caddy reverse-proxy config.
- `pki.tf` — root + intermediate CA (via the `tls` provider), consumed by step-ca.
- `secrets.tf` — `random_password` resources for generated service credentials.
- `outputs.tf` — VM IPs, service URLs, root CA cert, and generated secrets
  (`tofu output -json secrets`).
- `modules/vm/` — reusable module: clones the base image, builds the cloud-init ISO,
  and defines the `libvirt_domain` (UEFI/q35, host-passthrough CPU, SPICE console).
- `cloud-init/*.tmpl` — user-data (packages, quadlet container units, extra files)
  and network-config (DHCP or static IP) templates shared by every VM.
- `scripts/vhost-proxy.sh` — unix-socket proxy to the vhost's libvirtd (see below).

## Two libvirt connections

- Default provider (`var.libvirt_uri`, `qemu:///system`) — the local KVM host.
  Used by `main.tf` for ad hoc/test VMs.
- `libvirt.vhost` — the remote KVM host running the real services, reached over
  `qemu+unix:///system?socket=<vhost_socket_path>`. All VMs in `infra.tf` and
  `services.tf` use this provider via `providers = { libvirt = libvirt.vhost }`.

A direct `qemu+ssh://` URI hits a bug in the provider's statically-linked SSH
transport (`Cannot find start time for pid ...`), so the vhost connection instead
goes through a local unix socket proxied to the same `virt-ssh-helper` mechanism
`virsh` uses successfully.

**Before any `tofu` command that touches the vhost provider**, start the proxy:

```
scripts/vhost-proxy.sh
# or override defaults:
VHOST_HOST=... VHOST_SSH_USER=... VHOST_SSH_KEYFILE=... scripts/vhost-proxy.sh
```

Leave it running in a terminal (or under a process supervisor) for the duration of
the `tofu plan`/`apply`.

## Networking

- vhost service VMs attach to `var.vhost_bridge` (`br0`) with static IPs from
  `service_ips` in `services.tf`, on the vhost's real LAN.
- Two CoreDNS instances (`dns`, `dns2`) are authoritative for the `lab.internal`
  zone and forward everything else upstream to `var.vhost_dns`. Every VM's `dns =`
  list must contain **only** `service_ips.dns`/`dns2` — adding a public fallback
  makes systemd-resolved accept a public resolver's NXDOMAIN for `lab.internal` as
  final.
- They also serve a reverse zone `70.168.192.in-addr.arpa` (PTR records derived
  from `dns_a_records` in `infra.tf`), so `dig -x 192.168.70.20` returns
  `gitea.lab.internal.`. The reverse zone covers only the `192.168.70.0/24`
  octet the service IPs live in (the LAN mask is `/22`, but no lab hosts sit in
  the neighbouring `/24`s).
- Port 53 is published bound to the DNS VM's own LAN IP, not `0.0.0.0`:
  systemd-resolved's stub listener on `127.0.0.53:53` makes a wildcard bind fail.
- Web services sit behind per-VM Caddy, which requests certs from step-ca over
  ACME using the internal root CA (`pki.tf` / `outputs.tf: root_ca_pem`).
- docker.io image pulls go through a pull-through cache (`registry` VM); other
  service VMs get a `registries.conf.d` mirror drop-in pointing at it, with a
  direct docker.io fallback if the mirror is unreachable.

## Local npm registry (Gitea + Verdaccio)

Two VMs together form a self-contained npm supply chain: source is mirrored in
Gitea and compiled packages are published to Verdaccio.

- **Gitea** (`gitea-vm`, `https://gitea.lab.internal`, SSH on `:2222`) — a
  self-hosted git service. Mirror the source of your most-used npm packages here
  (either `git push` from upstream or use Gitea's "Migrate" UI to pull a mirror
  of an external repo). It reuses the standalone **Postgres VM** as its database:
  a one-shot `gitea-db-init` quadlet (Type=oneshot, runs once per boot and stays
  `active` via `RemainAfterExit`) connects to `postgres:5432` as the postgres
  superuser and idempotently creates the `gitea` role + `giteadb` database before
  the `gitea` container starts. Gitea then migrates its own schema on first run.
- **Verdaccio** (`verdaccio-vm`, `https://verdaccio.lab.internal`) — a local
  npm registry. Its config (`local.verdaccio_config` in `services.tf`) defines an
  `npmjs` uplink (`https://registry.npmjs.org/`, `cache: true`) so any package
  not yet published locally is transparently pulled from npmjs and cached on
  first hit. Auth uses the built-in `htpasswd` plugin with `max_users: 1`, so the
  first `npm adduser` against the registry becomes the sole publisher.

### Workflow: mirror → compile → host

1. **Mirror** the source of an npm package into Gitea (Gitea UI "Migrate" or
   `git push`).
2. **Compile** the package from that mirror on any machine with node:
   ```
   git clone ssh://git@gitea.lab.internal:2222/<you>/<package>.git
   cd <package>
   npm install
   npm run build      # or whatever the package's build script is
   npm version patch  # bump if you've patched the source
   ```
3. **Publish** to Verdaccio (point npm at it and publish as the authenticated
   user):
   ```
   npm config set registry https://verdaccio.lab.internal
   npm adduser         # first time only; creates the single htpasswd user
   npm publish         # publishes to the local store
   ```
4. **Consume** from anywhere on the LAN by configuring clients to use
   `https://verdaccio.lab.internal` as their registry. Pulls for packages you've
   published locally resolve from the Verdaccio store; everything else falls
   through to the npmjs uplink and is cached.

The gitea/verdaccio admin and DB credentials are in `tofu output -json secrets`
(`gitea_db_password`, `gitea_internal_token`, `gitea_secret_key`,
`gitea_jwt_secret`). The first Gitea user created through the web UI becomes the
admin; `INSTALL_LOCK=true` is already set so the installer page is skipped.

## Common tasks

Apply against the vhost (proxy must be running first):

```
tofu plan
tofu apply
```

Fetch generated credentials:

```
tofu output -json secrets
```

Fetch the root CA (to trust it locally, e.g. on Fedora):

```
tofu output -raw root_ca_pem | sudo tee /etc/pki/ca-trust/source/anchors/lab-internal-root-ca.crt
sudo update-ca-trust
```

### Rolling out config changes to an already-provisioned VM

cloud-init only runs on first boot, so a plain `tofu apply` that changes a
container, env var, or `extra_files` swaps the cloud-init ISO but an existing VM
never picks it up. Two options:

- **Non-destructive** (keeps podman named volumes/data): SSH to the VM and run
  `sudo cloud-init clean --logs && sudo reboot`.
- **Destructive** (fresh disk, wipes container volumes):
  `tofu apply -replace=module.<x>.libvirt_volume.disk -replace=module.<x>.libvirt_domain.vm`.
  On these q35/UEFI domains, always replace the domain together with the disk.

## Known gotchas

- **Provider version (0.9.8)**: `dmacvicar/libvirt` is pinned to `~> 0.9.8`.
  The 0.9.x line is a full rewrite to a deeply nested XML-mirroring schema using
  the Terraform plugin framework. HCL blocks (e.g. `cpu {}`, `disk {}`) are now
  nested objects (`cpu = { mode = ... }`, `disks = [{ source = ... }]`).
- **0.9.x volumes and pools cannot be updated in-place** — any diff forces
  replacement. All imported volumes and the pool have
  `lifecycle { ignore_changes = all }` so post-import drift (auto-populated
  allocation, permissions, timestamps, format metadata) doesn't trigger
  replacement.
- **0.9.x `libvirt_cloudinit_disk` is not importable**. The cloudinit ISOs were
  imported as `libvirt_volume` resources (with `create.content.url` pointing at
  the `libvirt_cloudinit_disk.init.path` output) instead.
- **0.9.x import ID formats**: pools by **UUID**, volumes by **full path**
  (key), domains by **UUID**. See `scripts/import-existing-state.sh`.
- **0.9.x vhost URI must be `qemu:///system?socket=...`** (bare `qemu` scheme,
  no `+unix` transport). The new dialer factory rejects `qemu+unix://` with
  "unsupported transport: unix" — use the bare scheme so `newLocalDialer()`
  picks up the `socket` query parameter.
- **`cpu.migratable` must be omitted**: the 0.9.x provider renders boolean
  `true`/`false` as `migratable='yes'`/`'no'` in the domain XML, but this
  libvirt version rejects both values. The `cpu_config` local omits the field
  entirely; the running VMs don't have it set.
- **UEFI requires `features.acpi = true`**: libvirt rejects UEFI domains
  without ACPI ("unsupported configuration: UEFI requires ACPI on this
  architecture"). The `features_config` local sets `acpi = true`.
- **Cloudinit volume format must be `"iso"`**: the 0.9.x provider detects the
  uploaded ISO format and returns `"iso"`; specifying `"raw"` causes a
  "Provider produced inconsistent result after apply" error.
- **Root disk `driver.type` must be `"qcow2"`**: if the disk `driver` object is
  omitted, the 0.9.x provider emits `<driver name='qemu' type='raw'/>` even
  though the root volumes are qcow2 overlays on the base cloud image. QEMU then
  reads the qcow2 header as a raw sector — no partition table / ESP — and UEFI
  reports "No bootable option or device was found". The disk object must set
  `driver = { name = "qemu", type = "qcow2" }`. (The SATA cdrom keeps
  `type='raw'`, which is correct for an ISO.)
- **Docker + libvirt on the same host**: Docker's `FORWARD` chain policy-drops
  traffic from libvirt bridges (e.g. `virbr0`) even though libvirt's own forward
  chain accepts it — both chains hook the same nftables `forward` priority. Fixed
  host-side via `DOCKER-USER` accept rules in a systemd unit
  (`docker-libvirt-forward.service`), not in this repo.
- **Root CA key lives in tfstate**: `pki.tf` generates the root/intermediate CA
  with the `tls` provider; only the intermediate cert/key are provisioned onto the
  CA VM. Accepted tradeoff here, consistent with `random_password` usage elsewhere.
- **Postgres `POSTGRES_PASSWORD` only applies on first init of an empty data
  dir**: the named `postgres-data` volume persists across container restarts, so
  changing the env (or recreating just the container) does NOT change the
  superuser password. If the volume was initialised with an old password, either
  `ALTER ROLE postgres WITH PASSWORD '...'` inside the container, or recreate the
  postgres VM (fresh disk → fresh podman storage → fresh volume).
- **`gitea-db-init` SQL must not use a nested shell heredoc with escaped
  dollar-quoting**: an earlier version emitted `DO \$\$ ... \$\$` (the terraform
  `\$\$` escape survived into the file literally), which psql rejected with
  `syntax error at or near "IF"`. The script now uses single `-c` statements with
  `-v ON_ERROR_STOP=1` and a bounded wait-for-postgres retry loop so first boot
  doesn't race postgres startup. See `local.gitea_init_script` in `services.tf`.
- **`cloud-init clean` on a running VM re-reads the OLD attached ISO**: the
  cloudinit cdrom media attached to a running domain is the ISO that existed when
  it booted. Replacing the `libvirt_cloudinit_disk` in the pool via `tofu apply`
  does not swap the running VM's attached media, and cloud-init caches per-instance
  state, so `cloud-init clean && reboot` alone won't pick up new `write_files`
  content. To roll out a changed cloud-init file, **recreate the VM**
  (`tofu -replace` the domain+disk), which attaches the fresh ISO.

## Planned / deferred

A second KVM host + Pacemaker HA for VM failover is a future goal, not yet built.
When it happens: point `pool_path` at shared storage, hand VM lifecycle to
Pacemaker's `VirtualDomain` resource agent (`libvirt_domain.running = false`), and
add a new `provider "libvirt" { alias = ... }` block per additional host in the
meantime (this provider has no built-in scheduler — placement is always explicit).
