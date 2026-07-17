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
  qvault, Penpot, Prometheus/Grafana, and the Aspire OTLP dashboard. Also defines
  `service_ips` (the static IP plan) and the shared Caddy reverse-proxy config.
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
- Port 53 is published bound to the DNS VM's own LAN IP, not `0.0.0.0`:
  systemd-resolved's stub listener on `127.0.0.53:53` makes a wildcard bind fail.
- Web services sit behind per-VM Caddy, which requests certs from step-ca over
  ACME using the internal root CA (`pki.tf` / `outputs.tf: root_ca_pem`).
- docker.io image pulls go through a pull-through cache (`registry` VM); other
  service VMs get a `registries.conf.d` mirror drop-in pointing at it, with a
  direct docker.io fallback if the mirror is unreachable.

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
  On these q35/UEFI domains, always replace the domain together with the disk —
  an in-place cloudinit ISO swap fails with "target hdd doesn't exist" because the
  cdrom is XSLT-renamed to `sda` (see `modules/vm/cdrom-sata.xsl`).

## Known gotchas

- **Provider version**: `dmacvicar/libvirt` must stay on `~> 0.8.0` (three-part
  constraint). `0.9.x` is a breaking rewrite to a deeply nested XML-mirroring
  schema; a two-part `~> 0.8` constraint can accidentally resolve to it.
- **Docker + libvirt on the same host**: Docker's `FORWARD` chain policy-drops
  traffic from libvirt bridges (e.g. `virbr0`) even though libvirt's own forward
  chain accepts it — both chains hook the same nftables `forward` priority. Fixed
  host-side via `DOCKER-USER` accept rules in a systemd unit
  (`docker-libvirt-forward.service`), not in this repo.
- **Root CA key lives in tfstate**: `pki.tf` generates the root/intermediate CA
  with the `tls` provider; only the intermediate cert/key are provisioned onto the
  CA VM. Accepted tradeoff here, consistent with `random_password` usage elsewhere.

## Planned / deferred

A second KVM host + Pacemaker HA for VM failover is a future goal, not yet built.
When it happens: point `pool_path` at shared storage, hand VM lifecycle to
Pacemaker's `VirtualDomain` resource agent (`libvirt_domain.running = false`), and
add a new `provider "libvirt" { alias = ... }` block per additional host in the
meantime (this provider has no built-in scheduler — placement is always explicit).
