# Grafana dashboards (provisioned)

Every `*.json` file in this directory is a Grafana dashboard **model** that is
shipped to the `monitoring` VM by `tofu apply` and auto-imported by Grafana's
file provisioner.

## How it is wired (see `services.tf`)

- `local.grafana_dashboards_provider` — the provider config, mounted at
  `/etc/grafana/provisioning/dashboards/infra.yml`. It watches
  `/etc/grafana/dashboards` and reloads every 30s.
- `local.grafana_dashboard_files` = `fileset(".../grafana/dashboards", "*.json")`
  — turned into one `extra_files` entry each at
  `/etc/monitoring/grafana-dashboards/<file>.json`.
- That directory is bind-mounted into the `grafana` container at
  `/etc/grafana/dashboards`.
- The Prometheus datasource is provisioned with a fixed `uid: prometheus`, so
  dashboards reference it as `{ "type": "prometheus", "uid": "prometheus" }`.

## Adding a dashboard

1. Drop the dashboard JSON here (e.g. export from the Grafana UI via
   *Share → Export → Save to file*, or download from grafana.com/dashboards).
2. Make sure the model has a stable `"uid"` and no `"id"` / `"__inputs"` /
   `"__requires"` blocks. If it came from grafana.com it will use an
   `${DS_PROMETHEUS}` input — replace those datasource refs with
   `{ "type": "prometheus", "uid": "prometheus" }`.
3. `tofu apply` (the VM's config-sync provisioner hot-pushes the file; Grafana
   picks it up within 30s — no container restart).

`allowUiUpdates` is `false`: edits made in the UI can be saved as a copy but the
provisioned dashboard always reverts to the file here. Treat this directory as
the source of truth.

## Current dashboards

| File | UID | Contents |
|------|-----|----------|
| `lab-overview.json` | `lab-overview` | Blackbox uptime probes, per-node CPU/mem/disk/load, Postgres/Redis/CoreDNS basics |
