# otel-fleet-collector

OpenTelemetry Collectors managed by OpenObserve **Fleet management**: agents on every node
(DaemonSet) or gateways for the cluster (StatefulSet).

Each pod runs the OpenTelemetry [OpAMP supervisor](https://github.com/open-telemetry/opentelemetry-collector-contrib/tree/main/cmd/opampsupervisor)
(image [`o2cr.ai/openobserve/otel-fleet-collector`](https://github.com/openobserve/otel-fleet-collector)),
which enrols against the OpenObserve server with a fleet enrollment token and receives the
collector configuration from the server. The chart ships **no collector configuration**: you
assign one in the OpenObserve UI, and the server pushes it to the collectors.

## Agents and gateways

A complete Kubernetes setup has two kinds of collectors with different jobs, permissions and
configurations:

| | Agent (`agent.enabled`, default) | Gateway (`gateway.enabled`) |
|---|---|---|
| Workload | DaemonSet, one pod per node | StatefulSet, `gateway.replicas` pods |
| Collects | Pod logs, journald, host metrics, kubelet stats, OTLP from the pods on its node | `k8s_cluster`, `k8s_events`, Prometheus scraping, OTLP from the agents, tail sampling |
| Access | Node log directories (root + `DAC_READ_SEARCH`), state on a hostPath; a ClusterRole to read pods and node stats | No node mounts, uid 65532, no capabilities; a ClusterRole to read cluster objects |
| Identity | Node name; state on the node | Pod name `<release>-<n>`; state on one PersistentVolumeClaim per replica |

The recommended topology is **agents → gateway → OpenObserve**: agents export OTLP to the
gateway Service, and the gateway runs the cluster-wide receivers and is the single egress to
OpenObserve. Agents can also export to OpenObserve directly and skip the gateway.

A release runs **one** of the two. It enrols with one fleet enrollment token, and every
collector in a fleet runs the same configuration, so agents and gateways are two fleets and
two releases, each with its own token. Enabling both in one release fails at render time.

### Multiple gateway replicas

Every gateway replica runs the gateway fleet's configuration:

- OTLP from the agents is spread over the replicas by the Service, with no duplication.
- `k8s_cluster`, `k8s_events` and `k8sobjects` must run once per cluster. Bind them to the
  `k8s_leader_elector` extension (`k8s_leader_elector: k8s_leader_elector` in the receiver)
  and only the replica holding the Lease runs them; another takes over within the lease
  duration (15s by default) when it goes away. The ClusterRole grants the Lease access.
- The `prometheus` receiver cannot be leader-elected: every replica scrapes every target and
  the samples are duplicated. `tail_sampling` needs all spans of a trace on one replica.
  Keep `gateway.replicas: 1` (the default) when the configuration uses either.

## Install

Open **Fleet management → Add collector → Kubernetes** in OpenObserve and pick **Agent** or
**Gateway**; it prints the command with your endpoint and the fleet's token filled in. For
agents:

```bash
helm repo add openobserve https://charts.openobserve.ai && helm repo update
helm upgrade --install otel-fleet-collector openobserve/otel-fleet-collector \
  --namespace openobserve-collector --create-namespace \
  --set image.repository=o2cr.ai/openobserve/otel-fleet-collector \
  --set image.tag='0.163.1' \
  --set opamp.endpoint='ws://openobserve.example.com:5080/api/default/v1/opamp' \
  --set opamp.token='<fleet enrollment token>'
```

For a gateway, in its own fleet and with that fleet's token:

```bash
helm upgrade --install otel-fleet-collector-gateway openobserve/otel-fleet-collector \
  --namespace openobserve-collector --create-namespace \
  --set agent.enabled=false --set gateway.enabled=true \
  --set image.repository=o2cr.ai/openobserve/otel-fleet-collector \
  --set image.tag='0.163.1' \
  --set opamp.endpoint='ws://openobserve.example.com:5080/api/default/v1/opamp' \
  --set opamp.token='<gateway fleet enrollment token>'
```

The gateway Service is named after the release, so agents in the same namespace reach it at
`otel-fleet-collector-gateway:4317` (gRPC) and `:4318` (HTTP).

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

## Kubernetes metadata on pod logs

Every collector gets its own pod's `K8S_NODE_NAME`, `K8S_POD_NAME` and `K8S_NAMESPACE`, plus
`K8S_CLUSTER_NAME` when `clusterName` is set. Kubernetes has no cluster name of its own, so set it
per cluster at install time (`--set clusterName=prod-us-east`); one fleet configuration then
serves every cluster and each collector fills in its own values.

To tag every pod log line with the cluster, node, pod and pod IP, assign the agent fleet a
configuration like this:

```yaml
receivers:
  filelog:
    include: [/var/log/pods/*/*/*.log]
    # The collectors' own logs, so they are not read back in a loop.
    exclude: [/var/log/pods/openobserve-collector_*/*/*.log]
    start_at: end
    include_file_path: true
    operators:
      # Parses the CRI/Docker line format and sets k8s.namespace.name, k8s.pod.name,
      # k8s.pod.uid and k8s.container.name from the file path.
      - type: container
processors:
  k8sattributes:
    filter:
      node_from_env_var: K8S_NODE_NAME
    pod_association:
      - sources: [{ from: resource_attribute, name: k8s.pod.uid }]
    extract:
      metadata: [k8s.pod.ip, k8s.node.name, k8s.deployment.name]
  resource/cluster:
    attributes:
      - { key: k8s.cluster.name, value: "${env:K8S_CLUSTER_NAME}", action: upsert }
  batch: {}
exporters:
  otlphttp/openobserve:
    endpoint: "${env:O2_ENDPOINT}"
    headers:
      Authorization: "${env:O2_TOKEN}"
service:
  pipelines:
    logs:
      receivers: [filelog]
      processors: [k8sattributes, resource/cluster, batch]
      exporters: [otlphttp/openobserve]
```

`k8s.pod.name` and `k8s.pod.ip` describe the pod that wrote the log line, so they come from the
file path and the `k8sattributes` processor, never from `K8S_POD_NAME`: that one is the
collector's own pod. `k8sattributes` uses the `agent.clusterRole` permissions, and
`filter.node_from_env_var` keeps each agent watching only the pods of its own node. Adjust the
`exclude` path when the chart is installed in another namespace.

## What gets deployed

For agents:

- A **DaemonSet** with one pod per node (control-plane nodes included by default) running the
  supervisor with `hostNetwork: false`, a read-only root filesystem, no privilege escalation,
  all capabilities dropped and the `RuntimeDefault` seccomp profile. See
  [Running as root](#running-as-root) for the uid.
- A **ConfigMap** with the `supervisor.yaml` template and a **Secret** with the token. An init
  container renders `Authorization: Basic base64("fleet:<token>")` into
  `/etc/opampsupervisor/supervisor.yaml`; the base64 is never something you provide.
- Supervisor state on the node at `agent.storage.hostPath` (default `/var/lib/opampsupervisor`), so a
  pod restart or chart upgrade keeps the node's agent instance id in Fleet management.
- `/var/log/pods` and `/var/lib/docker/containers` mounted read-only, for server-delivered
  configurations that use the `filelog` receiver.
- A ServiceAccount, and a **ClusterRole** and binding (`agent.clusterRole`) with read access to
  pods, namespaces, nodes and replicasets for the `k8sattributes` processor, plus `nodes/stats`
  for `kubeletstats`. Releases upgraded from 0.2.x get it too.

For gateways:

- A **StatefulSet** with `gateway.replicas` pods, run as uid 65532 with all capabilities
  dropped, a read-only root filesystem and nothing mounted from the node. A StatefulSet and not
  a Deployment, so pod names stay `<release>-0`, `<release>-1`, … and each replica keeps its
  instance id.
- One **PersistentVolumeClaim** per replica (`gateway.persistence`) for the supervisor state.
  With `gateway.persistence.enabled: false` the state is an emptyDir, and every rescheduled pod
  enrols as a new collector while the old one stays behind as offline.
- A **ClusterIP Service** (`gateway.service`) on 4317/4318 for the agents, and a headless Service
  for per-pod DNS. The fleet configuration's `otlp` receiver must listen on `0.0.0.0`; the
  collector default is `localhost`.
- A **ClusterRole** and binding (`gateway.clusterRole`) with read access to the objects
  `k8s_cluster`, `k8s_events`, `k8sobjects`, `k8sattributes` and `kubernetes_sd_configs` read,
  plus `coordination.k8s.io/leases` for `k8s_leader_elector`.

Both get:

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
  config_apply_timeout: 30s
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
this chart therefore runs the agent container **as root** when `agent.hostLogs.enabled` is
`true` (the default), with only the `DAC_READ_SEARCH` capability added: it grants read access
to root-owned files and nothing more. The read-only root filesystem, `allowPrivilegeEscalation:
false`, the other dropped capabilities and the seccomp profile stay in place, and the state
directory on the node remains root-owned.

With `agent.hostLogs.enabled: false` the pod runs as the image's non-root uid 65532 and no capability
is added. Either way the init container chowns the state directory on the node to the uid the
supervisor runs as, so switching the setting on an existing install, or upgrading from chart
0.1.0 (which always ran as 65532), keeps working. Gateways never mount node files and always
run as 65532.

## Upgrading from 0.1.x

0.2.0 moved the node-specific values under `agent`: `storage`, `hostLogs`, `resources`,
`nodeSelector`, `tolerations`, `affinity` and `updateStrategy` are now `agent.storage`,
`agent.hostLogs` and so on (the last four exist under `gateway` too). With the defaults the
rendered agent DaemonSet is unchanged. A release that still sets one of the old top-level keys
fails to render with a message naming the new key, rather than silently dropping the setting.

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
| `clusterName` | `""` | Cluster name, exposed to the collector as `K8S_CLUSTER_NAME` (see [Kubernetes metadata on pod logs](#kubernetes-metadata-on-pod-logs)) |
| `agent.enabled` | `true` | Run agents: a DaemonSet with one collector per node. Exactly one of `agent.enabled` and `gateway.enabled` |
| `agent.storage.hostPath` | `/var/lib/opampsupervisor` | Node directory for supervisor state (instance id, last config) |
| `agent.hostLogs.enabled` | `true` | Mount host log directories read-only and run the supervisor as root with `DAC_READ_SEARCH` (see [Running as root](#running-as-root)); `false` runs as uid 65532 |
| `agent.hostLogs.paths` | `[/var/log/pods, /var/lib/docker/containers]` | Which directories |
| `agent.clusterRole.create` | `true` | ClusterRole and binding for `k8sattributes` and `kubeletstats` |
| `agent.clusterRole.rules` | `[]` | Extra rules appended to the ClusterRole |
| `agent.resources` | `{}` | Supervisor container resources |
| `agent.nodeSelector` | `{}` | |
| `agent.tolerations` | `[{operator: Exists}]` | Run on every node, tainted ones included |
| `agent.affinity` | `{}` | |
| `agent.updateStrategy` | `RollingUpdate`, `maxUnavailable: 1` | |
| `gateway.enabled` | `false` | Run gateways: a StatefulSet. Set `agent.enabled=false` with it |
| `gateway.replicas` | `1` | Pods; see [Multiple gateway replicas](#multiple-gateway-replicas) |
| `gateway.persistence.enabled` | `true` | One PVC per replica for supervisor state; `false` uses an emptyDir (identity changes on reschedule) |
| `gateway.persistence.size` | `1Gi` | |
| `gateway.persistence.storageClass` | `""` | Empty uses the default StorageClass; `-` sets `storageClassName: ""` |
| `gateway.persistence.accessModes` | `[ReadWriteOnce]` | |
| `gateway.service.enabled` | `true` | ClusterIP and headless Services for OTLP from the agents |
| `gateway.service.type` | `ClusterIP` | |
| `gateway.service.annotations` | `{}` | |
| `gateway.service.ports` | `otlp-grpc` 4317, `otlp-http` 4318 | Also the container ports |
| `gateway.clusterRole.create` | `true` | ClusterRole and binding for the cluster receivers and leader election |
| `gateway.clusterRole.rules` | `[]` | Extra rules appended to the ClusterRole |
| `gateway.resources` | `{}` | Supervisor container resources |
| `gateway.nodeSelector` | `{}` | |
| `gateway.tolerations` | `[]` | |
| `gateway.affinity` | `{}` | |
| `initContainer.image.repository` | `busybox` | Image of the init container that renders the token and chowns the state dir |
| `initContainer.image.tag` | `1.37` | |
| `initContainer.image.pullPolicy` | `IfNotPresent` | |
| `initContainer.resources` | `{}` | |
| `serviceAccount.create` | `true` | |
| `serviceAccount.annotations` | `{}` | |
| `serviceAccount.name` | `""` | Generated from the release name when empty |
| `podAnnotations` | `{}` | |
| `podLabels` | `{}` | |
| `podSecurityContext` | uid/gid 65532, `runAsNonRoot`, `RuntimeDefault` seccomp | Pod security context; for agents with `agent.hostLogs.enabled` the chart sets uid/gid 0 and `runAsNonRoot: false` |
| `securityContext` | no privilege escalation, read-only root fs, all capabilities dropped | Supervisor container security context; for agents with `agent.hostLogs.enabled` the chart adds `DAC_READ_SEARCH` |
| `extraEnv` | `[]` | Extra env vars for the supervisor container |
| `priorityClassName` | `""` | |
| `terminationGracePeriodSeconds` | `30` | Keep >= 15: the supervisor SIGKILLs the collector 10s after SIGTERM |
| `extraVolumes` | `[]` | |
| `extraVolumeMounts` | `[]` | |
| `nameOverride` / `fullnameOverride` | `""` | |

## Uninstall

```bash
helm -n openobserve-collector uninstall otel-fleet-collector
```

The state directory stays on each node. Remove `agent.storage.hostPath` there if you want the
nodes to re-enrol with fresh instance ids next time. A gateway's PersistentVolumeClaims
(`state-<release>-<n>`) are kept too; delete them for fresh gateway instance ids:

```bash
helm -n openobserve-collector uninstall otel-fleet-collector-gateway
kubectl -n openobserve-collector delete pvc -l app.kubernetes.io/instance=otel-fleet-collector-gateway
```
