# Logs Collection

Two log sources are collected: container stdout/stderr and Kubernetes Events.

---

## 1. Container Logs

**Collector:** Agent DaemonSet
**Receiver:** `filelog/std`
**OpenObserve stream:** `default` (logs)
**Source path:** `/var/log/pods/*/*/*.log` on each node

### What is collected

All pod/container stdout and stderr logs from every node. The collector auto-detects the container runtime format and parses accordingly:

| Runtime | Format detected by |
|---------|-------------------|
| Docker | JSON body starting with `{` |
| containerd | Timestamp ending in `Z` |
| CRI-O | Timestamp without trailing `Z` |

### Excluded logs

| Pattern | Reason |
|---------|--------|
| `/var/log/pods/*/otel-collector/*.log` | Avoid collector self-logging loop |
| `/var/log/pods/*/otc-container/*.log` | Avoid otel-contrib self-logging loop |
| `/var/log/pods/*/openobserve-ingester/*.log` | Ingester logs are massive and cyclic |

### Fields attached to every log entry

From the file path and Kubernetes metadata:

| Field | Example | Source |
|-------|---------|--------|
| `k8s.pod.name` | `nginx-abc123` | k8sattributes processor |
| `k8s.pod.uid` | `abc-123-...` | extracted from file path |
| `k8s.namespace.name` | `production` | k8sattributes processor |
| `k8s.node.name` | `ip-10-0-1-5` | k8sattributes processor |
| `k8s.deployment.name` | `nginx` | k8sattributes processor |
| `k8s.container.name` | `nginx` | k8sattributes processor |
| `k8s.pod.start_time` | `2024-01-01T00:00:00Z` | k8sattributes processor |
| `log.iostream` | `stdout` or `stderr` | parsed from log line |
| `log.file.path` | `/var/log/pods/...` | filelog receiver |
| `service.name` | `nginx` | from `app.kubernetes.io/name` label |
| `service.version` | `1.2.3` | from `app.kubernetes.io/version` label |
| `container.image.name` | `nginx` | k8sattributes processor |
| `container.image.tag` | `1.25` | k8sattributes processor |

---

## 2. Kubernetes Events

**Collector:** Gateway StatefulSet
**Receiver:** `k8sobjects/events`
**OpenObserve stream:** `k8s_events`
**Mode:** `watch` (real-time stream from Kubernetes Events API)

### What is collected

All Kubernetes events cluster-wide — every `kubectl describe` event, scheduler decisions, pod state changes, image pulls, OOMKills, etc.

### Example events captured

| Reason | Message example |
|--------|----------------|
| `Scheduled` | Successfully assigned default/nginx-xxx to node-1 |
| `Pulled` | Successfully pulled image "nginx:1.25" |
| `Started` | Started container nginx |
| `BackOff` | Back-off restarting failed container |
| `OOMKilling` | Memory limit exceeded |
| `FailedMount` | Unable to attach or mount volumes |
| `ScalingReplicaSet` | Scaled up replica set nginx-xxx to 3 |
| `FailedScheduling` | 0/3 nodes are available: insufficient memory |

### Key fields

| Field | Description |
|-------|-------------|
| `body.reason` | Event reason (e.g. `Scheduled`, `BackOff`) |
| `body.message` | Human-readable event message |
| `body.type` | `Normal` or `Warning` |
| `body.involvedObject.kind` | Object type (Pod, Node, Deployment, etc.) |
| `body.involvedObject.name` | Object name |
| `body.involvedObject.namespace` | Namespace |
| `body.count` | How many times this event occurred |
| `body.firstTimestamp` | When it first occurred |
| `body.lastTimestamp` | Most recent occurrence |
| `body.source.component` | Component that generated the event (e.g. `kubelet`, `scheduler`) |
| `body.source.host` | Node where the event originated |
