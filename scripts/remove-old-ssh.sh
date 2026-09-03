#!/bin/bash
# Remove stale SSH host keys for all lab VMs (IPs 10-26 on 192.168.70.x)
# plus their lab.internal hostnames. Run this after rebuilding VMs or
# when SSH warns about changed host keys.

set -euo pipefail

for i in $(seq 10 26); do
    ip="192.168.70.$i"
    ssh-keygen -R "$ip" 2>/dev/null || true
done

# Hostnames from services.tf + infra.tf
hostnames=(
    # Core infra
    surrealdb.lab.internal
    postgres.lab.internal
    qvault.lab.internal
    penpot.lab.internal
    monitoring.lab.internal
    aspire.lab.internal
    dns1.lab.internal
    dns2.lab.internal
    dns.lab.internal
    dns-lb.lab.internal
    ca.lab.internal
    registry.lab.internal
    gitea.lab.internal
    verdaccio.lab.internal
    nfs.lab.internal
    redis.lab.internal
    gitea-runner-1.lab.internal
    gitea-runner-2.lab.internal
    # CNAMEs / aliases
    prometheus.lab.internal
    grafana.lab.internal
    ntfy.lab.internal
    vhost
    vhost.lab.internal
)

for host in "${hostnames[@]}"; do
    ssh-keygen -R "$host" 2>/dev/null || true
done

echo "Removed stale SSH keys for 192.168.70.10-26 and ${#hostnames[@]} lab.internal hostnames"
