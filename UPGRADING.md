# Upgrading the OpenObserve Helm charts

This document highlights upgrades that need manual attention. If a chart version is
**not** listed here, upgrading is expected to be a straight `helm upgrade` with no manual
steps. Chart versions follow [Semantic Versioning](https://semver.org/); a bump in the
**major** chart version signals a potentially breaking change to the chart itself.

> Tip: always review the rendered diff before applying an upgrade:
>
> ```bash
> helm diff upgrade <release> openobserve/<chart> -f your-values.yaml   # requires the helm-diff plugin
> ```

## How to read this file

- **App upgrades** — bumping the OpenObserve application (`appVersion`), e.g. `0.9.x → 0.10.x`.
  Application-level breaking changes (schema/meta-store migrations, renamed env vars) are the
  application's own; check the [OpenObserve release notes](https://github.com/openobserve/openobserve/releases).
- **Chart upgrades** — breaking changes to the chart templates/values themselves (renamed
  values, moved keys, renamed resources).

## Chart changes

### openobserve-standalone — Postgres DSN moved to the Secret

`ZO_META_POSTGRES_DSN` is now rendered into the **Secret** instead of the plaintext ConfigMap,
and a new `auth.ZO_META_POSTGRES_DSN` takes precedence over `config.ZO_META_POSTGRES_DSN` when
set. No values change is required — the existing `config.ZO_META_POSTGRES_DSN` is still honored
and the StatefulSet consumes it via `envFrom`. This is transparent on `helm upgrade`.

### openobserve / openobserve-standalone — cert-manager issuer annotation

The default `ingress.annotations` no longer hardcodes `cert-manager.io/issuer: letsencrypt`.
- If you rely on the **built-in** Issuer, set `certIssuer.enabled: true` — the annotation is then
  injected automatically.
- If you use your **own** `cert-manager.io/cluster-issuer`, just set it under `ingress.annotations`;
  there is no longer a conflicting `issuer` annotation.

### openobserve-standalone — persistence.enabled now gates the PVC

`persistence.enabled: false` now actually removes the data `volumeClaimTemplate` and backs `/data`
with an ephemeral `emptyDir`. Previously the PVC was always created. If you were setting
`persistence.enabled: false` and unknowingly still getting a PVC, you will now get ephemeral
storage — set it back to `true` if you need the PVC.

### openobserve-collector 0.5.0 — scrape `sample_limit` moved to `gateway.prometheus.sampleLimit`

The `cadvisor` and `prometheus-autodiscovery` jobs no longer carry a literal `sample_limit`
in `gateway.receivers.prometheus.config.scrape_configs`; the template sets it from
`gateway.prometheus.sampleLimit` (default `10000`; `0` = no per-job limit). Default installs render
unchanged. If you override `scrape_configs`, a `sample_limit` you set on either job still
wins — but if your copy **omits** it on either job (to run unlimited, or to inherit a
`global.sample_limit`), that job now gets 10000: set `gateway.prometheus.sampleLimit: 0`
to keep the previous behavior.

### openobserve-collector 0.5.1 — collector 0.163.1 renames `container.image.tag`

The gateway now emits `container.image.tags` (an array) instead of `container.image.tag`: upstream
k8sattributes stops emitting the old key from collector 0.161. In OpenObserve the
fields change name and shape: on metrics `container_image_tag` becomes `container_image_tags`, and
on traces `service_container_image_tag` becomes `service_container_image_tags`. The new value is
stored as a JSON array string, so update saved queries, dashboards and alerts that filter on it:
`container_image_tag = '1.25'` becomes `container_image_tags = '["1.25"]'`.

Also from 0.161, `container.cpu.usage`, `k8s.pod.cpu.usage` and `k8s.node.cpu.usage` are computed
as the rate of the matching `*.cpu.time` counter between scrapes, so they are not reported on the
first scrape after an agent starts.

### openobserve-collector 0.6.0 — eBPF tracing; Go `Instrumentation` deprecated

The new `ebpf` values add an optional eBPF tracing DaemonSet. It is off by default, and with
`ebpf.enabled: false` the chart renders the same resources as 0.5.1, so upgrading needs no
action. To enable it, the OpenTelemetry Operator must be **v0.142.0 or later** (tested with v0.161.0): older operators
reject or silently drop `spec.hostPID`, and the pods then trace nothing. If that happened, upgrading
the operator does not restore the field: run `helm upgrade --force` (`--force-replace` on Helm 4), or delete the
`<fullname>-ebpf` `OpenTelemetryCollector` and upgrade. The release namespace must also allow
privileged pods.

The Go `Instrumentation` resource (`openobserve-go`) and `autoinstrumentation.goImageVersion`
are deprecated and will be removed in a later release; they keep working in 0.6.0. To migrate a
pod, remove its `instrumentation.opentelemetry.io/inject-go` annotation and select the app with
`ebpf.trace` (port, executable path or command line). Don't select a pod with `ebpf.trace` while
it still uses the Go sidecar, or its spans are duplicated.

### openobserve 1.0.3 / openobserve-standalone 1.0.2 — service graph settings for OpenObserve 1.2.0

OpenObserve 1.2.0 removes the first-generation service graph job. Its settings
`O2_SERVICE_GRAPH_PROCESSING_INTERVAL_SECS`, `O2_SERVICE_GRAPH_QUERY_TIME_RANGE_MINUTES` and
`O2_SERVICE_GRAPH_EXCLUDE_INTERNAL_SPANS` are gone from `enterprise.parameters` and are ignored by
the server; remove them from your values. The rollup that replaces it is tuned with
`O2_SERVICE_GRAPH_INTERVAL_SECS` and `O2_SERVICE_GRAPH_FLUSH_SECS` (both default `60`).

`enterprise.parameters.O2_SERVICE_GRAPH_ENABLED` now defaults to `"true"`, matching the server's
default, so enterprise installs start building the service graph after the upgrade. Set it to
`"false"` to keep it off. If a collector in front of OpenObserve also runs the OpenTelemetry
`servicegraph` connector for the same organization, the service graph page uses only OpenObserve's
series, but your own PromQL over `traces_service_graph_*` counts every request twice unless it
matches `trace_stream` (see the openobserve-collector 0.7.0 entry below).

The new `config.ZO_SSRF_ALLOW_LOOPBACK`, `config.ZO_SKIP_SSRF_CHECKS`, `config.ZO_SSRF_ALLOWED_CIDRS`
and `config.ZO_SSRF_ALLOWED_HOSTS` keys, and `enterprise.parameters.O2_AGENT_SIGNALS_PROCESSING_INTERVAL_SECS`,
expose existing server settings with the server's defaults; they need no action.

### openobserve-collector 0.7.0 — `servicegraph` connector off by default

The gateway still defines the `servicegraph` connector but no longer puts it in its pipelines, so
it stops sending the `traces_service_graph_*` metrics. OpenObserve Enterprise builds the service
graph from traces on the server and writes metrics under the same names. If you rely on the
connector's metrics (for example with the open-source edition), add `servicegraph` back to the
metrics receivers and traces exporters as shown in
[traces.md — Service Graph](charts/openobserve-collector/docs/traces.md#service-graph).

### openobserve 1.0.4 / openobserve-standalone 1.0.3 — shared secret between OpenObserve and the report server

The charts now create a Secret `<fullname>-report-server` holding `ZO_REPORT_SERVER_SECRET`, so
OpenObserve and the report server share one secret; newer report-server images refuse to start
without it. If `auth.ZO_REPORT_SERVER_SECRET` is empty, the chart generates a random value on install
and keeps it on later `helm upgrade`s. It is injected only into the pods that use it: ingester,
scheduler and reportserver (in openobserve-standalone, the single OpenObserve pod), which restart
once when it first appears. The Secret is created also with `externalSecret.enabled`, so no change
to your own Secret is needed.

With `helm template` or ArgoCD, the chart cannot read the existing Secret, so an empty value
changes on every render: set `auth.ZO_REPORT_SERVER_SECRET` explicitly.

### openobserve 1.1.3 / openobserve-standalone 1.1.3 — master encryption key reaches OpenObserve

`enterprise.parameters.ZO_MASTER_ENCRYPTION_KEY` was rendered as `ZO_MASTER_ENCRYPTION_KEY`, a name
OpenObserve never reads, so installs that set it ran with no master key. The chart now renders it as
`O2_MASTER_ENCRYPTION_KEY` in the chart's Secret, and `ZO_MASTER_ENCRYPTION_ALGORITHM` as
`O2_MASTER_ENCRYPTION_ALGORITHM` in the ConfigMap, only when set. The OpenObserve pods restart once.

If you set the key, check it before upgrading, because OpenObserve now reads it:

- An invalid key, or an algorithm other than `aes-256-siv`, makes every OpenObserve pod fail at
  boot. The key must be 64 random bytes, base64-encoded, for example from
  `openssl rand -base64 64 | tr -d '\n'`. If you do not want encryption at rest, clear both values.
- A valid key turns on encryption at rest for the first time: at boot OpenObserve re-encrypts the
  stored secrets with it. From then on keep the key; if you lose it, those secrets cannot be read.

If you set `O2_MASTER_ENCRYPTION_KEY` through `extraEnv` as a workaround, that value still wins and
you can now remove it. With `externalSecret.enabled`, add `O2_MASTER_ENCRYPTION_KEY` to your own
Secret instead.

## Application upgrades

For OpenObserve application upgrades (the `appVersion` / image tag), always consult the
upstream release notes for migration steps before upgrading:
<https://github.com/openobserve/openobserve/releases>.

### otel-fleet-collector 0.4.0 — node IP and /hostfs on agents

Agents now get `K8S_NODE_IP` and, with `agent.hostMetrics.enabled: true` (the default), the
node's `/` mounted read-only at `/hostfs`. If you added either through `extraEnv`,
`extraVolumes` or `extraVolumeMounts`, remove them before upgrading: a second `hostfs` volume or
`/hostfs` mount makes the DaemonSet invalid. Set `agent.hostMetrics.enabled: false` to keep the
node's root filesystem out of the pod.

### otel-fleet-collector 0.1.1 — runs as root when collecting host logs

With `hostLogs.enabled: true` (the default) the supervisor container now runs as root with the
`DAC_READ_SEARCH` capability, because node log files under `/var/log/pods` are root-owned and
not world-readable; 0.1.0 ran as uid 65532 and the `filelog` receiver read nothing. The init
container re-chowns the state directory on each node to root, so a plain `helm upgrade` is
enough. Set `hostLogs.enabled: false` to keep the non-root setup (and no host log collection).
