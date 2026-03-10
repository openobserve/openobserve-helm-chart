# Traces Collection

**Collector:** Gateway StatefulSet
**Receiver:** `otlp` (gRPC + HTTP)
**OpenObserve stream:** `default` (traces)

---

## OTLP Receiver

The gateway accepts traces from any application instrumented with OpenTelemetry via:

| Protocol | Endpoint | Default Port |
|----------|----------|-------------|
| gRPC | `<gateway-service>:4317` | 4317 |
| HTTP | `<gateway-service>:4318` | 4318 |

Send traces from your application by setting the OTLP exporter endpoint to the gateway service address.

---

## Auto-Instrumentation

The chart includes an OpenTelemetry **auto-instrumentation** resource that injects OpenTelemetry SDKs into pods without code changes.

**Sampling rate:** 100% (configurable via `autoinstrumentation.samplingRate`)

### Supported languages

Enable per pod or namespace by adding the appropriate annotation:

| Language | Annotation |
|----------|-----------|
| Java | `instrumentation.opentelemetry.io/inject-java: "true"` |
| Node.js | `instrumentation.opentelemetry.io/inject-nodejs: "true"` |
| Python | `instrumentation.opentelemetry.io/inject-python: "true"` |
| .NET | `instrumentation.opentelemetry.io/inject-dotnet: "true"` |
| Go | `instrumentation.opentelemetry.io/inject-go: "true"` + `instrumentation.opentelemetry.io/otel-go-auto-target-exe: "/path/to/binary"` |
| SDK env vars only | `instrumentation.opentelemetry.io/inject-sdk: "true"` |

> **Go** uses eBPF and requires privileged mode. It is disabled by default in the operator and must be enabled via `opentelemetry-operator.manager.featureGates`.

> **Python logs** auto-instrumentation is disabled by default (`autoinstrumentation.pythonLogsEnabled: false`).

### What auto-instrumentation captures

Depending on the language and framework, auto-instrumentation typically produces spans for:

- Incoming HTTP requests (server spans)
- Outgoing HTTP calls (client spans)
- Database queries (PostgreSQL, MySQL, MongoDB, Redis)
- Message queue operations (Kafka, RabbitMQ)
- gRPC calls
- Framework-specific operations (Spring, Express, Django, Flask, ASP.NET, etc.)

---

## Span Attributes

The `k8sattributes` processor enriches every span with Kubernetes metadata:

| Attribute | Description |
|-----------|-------------|
| `k8s.pod.name` | Pod generating the trace |
| `k8s.pod.uid` | Pod UID |
| `k8s.namespace.name` | Namespace |
| `k8s.node.name` | Node name |
| `k8s.deployment.name` | Deployment name |
| `k8s.replicaset.name` | ReplicaSet name |
| `k8s.daemonset.name` | DaemonSet name (if applicable) |
| `k8s.statefulset.name` | StatefulSet name (if applicable) |
| `k8s.job.name` | Job name (if applicable) |
| `k8s.cronjob.name` | CronJob name (if applicable) |
| `k8s.container.name` | Container name |
| `k8s.cluster.uid` | Cluster UID |
| `container.image.name` | Container image name |
| `container.image.tag` | Container image tag |
| `service.name` | From `app.kubernetes.io/name` label |
| `service.version` | From `app.kubernetes.io/version` label |

---

## Service Graph

The `servicegraph` connector processes incoming traces and derives **service-to-service call metrics** automatically. No configuration needed in applications.

See [metrics.md — Service Graph](metrics.md#12-service-graph) for the generated metrics.

**How it works:**
1. Client span and matching server span are paired by trace/span ID
2. Latency is computed from the span duration
3. Metrics are emitted with `client` and `server` service labels
4. Unmatched spans are held for 30s (TTL) then dropped

---

## Operator Installation

The OpenTelemetry Operator (`opentelemetry-operator`) is **disabled by default** in this chart (`opentelemetry-operator.enabled: false`). It is required for auto-instrumentation to work.

If you install the operator separately, set `opentelemetry-operator.enabled: false` and `autoinstrumentation.enabled: true` to only deploy the instrumentation CR.

If you want the chart to manage the operator, set `opentelemetry-operator.enabled: true`. The operator requires cert-manager or self-signed certs for its admission webhook.
