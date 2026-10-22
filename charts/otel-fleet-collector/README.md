# otel-fleet-collector

An OpenTelemetry Collector on every node, managed by OpenObserve **Fleet management**.

Each pod runs the OpenTelemetry [OpAMP supervisor](https://github.com/open-telemetry/opentelemetry-collector-contrib/tree/main/cmd/opampsupervisor)
(image [`o2cr.ai/openobserve/otel-fleet-collector`](https://github.com/openobserve/otel-fleet-collector)),
which enrols against the OpenObserve server with a fleet enrollment token and receives the
collector configuration from the server. The chart ships **no collector configuration**: you
assign one in the OpenObserve UI, and the server pushes it to the collectors.

## Install

Open **Fleet management → Add collector → Kubernetes** in OpenObserve; it prints this command
with your endpoint and token filled in:

```bash
helm repo add openobserve https://charts.openobserve.ai && helm repo update
helm upgrade --install otel-fleet-collector openobserve/otel-fleet-collector \
  --namespace openobserve-collector --create-namespace \
  --set image.repository=o2cr.ai/openobserve/otel-fleet-collector \
  --set image.tag='0.163.1' \
  --set opamp.endpoint='ws://openobserve.example.com:5080/api/default/v1/opamp' \
  --set opamp.token='<fleet enrollment token>'
```

`opamp.endpoint` is `<scheme>://<host>/api/<org>/v1/opamp`, with `ws://` for an http server
and `wss://` for https. Re-running the command upgrades or reconfigures the release.

### Keeping the token out of values

Create the Secret yourself and point the chart at it:

```bash
kubectl -n openobserve-collector create secret generic fleet-token --from-literal=token='<fleet enrollment token>'
helm upgrade --install otel-fleet-collector openobserve/otel-fleet-collector \
  --namespace openobserve-collector --create-namespace \
  --set opamp.endpoint='wss://openobserve.example.com/api/default/v1/opamp' \
  --set opamp.existingSecret=fleet-token
```

## What gets deployed

- A **DaemonSet** with one pod per node (control-plane nodes included by default) running the
  supervisor with `hostNetwork: false`, a read-only root filesystem, no privilege escalation,
  all capabilities dropped and the `RuntimeDefault` seccomp profile. See
  [Running as root](#running-as-root) for the uid.
- A **ConfigMap** with the `supervisor.yaml` template and a **Secret** with the token. An init
  container renders `Authorization: Basic base64("fleet:<token>")` into
  `/etc/opampsupervisor/supervisor.yaml`; the base64 is never something you provide.
- Supervisor state on the node at `storage.hostPath` (default `/var/lib/opampsupervisor`), so a
  pod restart or chart upgrade keeps the node's agent instance id in Fleet management.
- `/var/log/pods` and `/var/lib/docker/containers` mounted read-only, for server-delivered
  configurations that use the `filelog` receiver.
- A ServiceAccount (no RBAC rules; add a ClusterRole yourself if the configuration you assign
  uses the `k8sattributes` or `k8s_cluster` receivers/processors).

The rendered `supervisor.yaml` matches the one the Docker install command writes:

```yaml
server:
  endpoint: ws://openobserve.example.com:5080/api/default/v1/opamp
  headers:
    Authorization: "Basic <base64 of fleet:<token>>"
  tls:              # only for ws:// endpoints or opamp.insecureTls=true
    insecure: true
capabilities:
  accepts_remote_config: true
  reports_effective_config: true
  reports_health: true
  reports_own_metrics: true
  accepts_restart_command: true
  reports_available_components: true
agent:
  executable: /usr/local/bin/otelcol-contrib
  passthrough_logs: true
  env:
    O2_ENDPOINT: http://openobserve.example.com:5080/api/default
    O2_TOKEN: "Basic <base64 of fleet:<token>>"
storage:
  directory: /var/lib/opampsupervisor
```

## Running as root

Node log files are owned by root and not world-readable (`/var/log/pods` is
`drwxr-x--- root root`, the files `-rw-r----- root root`), so a non-root collector reads
nothing from them. Like the upstream OpenTelemetry collector chart does for log collection,
this chart therefore runs the supervisor container **as root** when `hostLogs.enabled` is
`true` (the default), with only the `DAC_READ_SEARCH` capability added: it grants read access
to root-owned files and nothing more. The read-only root filesystem, `allowPrivilegeEscalation:
false`, the other dropped capabilities and the seccomp profile stay in place, and the state
directory on the node remains root-owned.

With `hostLogs.enabled: false` the pod runs as the image's non-root uid 65532 and no capability
is added. Either way the init container chowns the state directory on the node to the uid the
supervisor runs as, so switching the setting on an existing install, or upgrading from chart
0.1.0 (which always ran as 65532), keeps working.

## Values

| Key | Default | Description |
|-----|---------|-------------|
| `image.repository` | `o2cr.ai/openobserve/otel-fleet-collector` | Supervisor + collector image |
| `image.tag` | `0.163.1` | Image tag (chart `appVersion` when empty) |
| `image.pullPolicy` | `IfNotPresent` | |
| `imagePullSecrets` | `[]` | |
| `opamp.endpoint` | `""` | **Required.** OpAMP websocket URL `ws(s)://<host>/api/<org>/v1/opamp` |
| `opamp.token` | `""` | Fleet enrollment token; stored in a chart-managed Secret. Required unless `opamp.existingSecret` is set |
| `opamp.existingSecret` | `""` | Existing Secret holding the token; takes precedence over `opamp.token` |
| `opamp.existingSecretKey` | `token` | Key of the token in `opamp.existingSecret` |
| `opamp.insecureTls` | `false` | Skip TLS verification (self-signed certificates). `ws://` endpoints get `tls.insecure: true` regardless |
| `supervisor.passthroughLogs` | `true` | Forward the collector's logs to the pod's stdout |
| `storage.hostPath` | `/var/lib/opampsupervisor` | Node directory for supervisor state (instance id, last config) |
| `hostLogs.enabled` | `true` | Mount host log directories read-only and run the supervisor as root with `DAC_READ_SEARCH` (see [Running as root](#running-as-root)); `false` runs as uid 65532 |
| `hostLogs.paths` | `[/var/log/pods, /var/lib/docker/containers]` | Which directories |
| `initContainer.image.repository` | `busybox` | Image of the init container that renders the token and chowns the state dir |
| `initContainer.image.tag` | `1.37` | |
| `initContainer.image.pullPolicy` | `IfNotPresent` | |
| `initContainer.resources` | `{}` | |
| `serviceAccount.create` | `true` | |
| `serviceAccount.annotations` | `{}` | |
| `serviceAccount.name` | `""` | Generated from the release name when empty |
| `podAnnotations` | `{}` | |
| `podLabels` | `{}` | |
| `podSecurityContext` | uid/gid 65532, `runAsNonRoot`, `RuntimeDefault` seccomp | Pod security context; with `hostLogs.enabled` the chart sets uid/gid 0 and `runAsNonRoot: false` |
| `securityContext` | no privilege escalation, read-only root fs, all capabilities dropped | Supervisor container security context; with `hostLogs.enabled` the chart adds `DAC_READ_SEARCH` |
| `extraEnv` | `[]` | Extra env vars for the supervisor container |
| `resources` | `{}` | Supervisor container resources |
| `nodeSelector` | `{}` | |
| `tolerations` | `[{operator: Exists}]` | Run on every node, tainted ones included |
| `affinity` | `{}` | |
| `priorityClassName` | `""` | |
| `terminationGracePeriodSeconds` | `30` | Keep >= 15: the supervisor SIGKILLs the collector 10s after SIGTERM |
| `updateStrategy` | `RollingUpdate`, `maxUnavailable: 1` | |
| `extraVolumes` | `[]` | |
| `extraVolumeMounts` | `[]` | |
| `nameOverride` / `fullnameOverride` | `""` | |

## Uninstall

```bash
helm -n openobserve-collector uninstall otel-fleet-collector
```

The state directory stays on each node. Remove `storage.hostPath` there if you want the nodes to
re-enrol with fresh instance ids next time.
