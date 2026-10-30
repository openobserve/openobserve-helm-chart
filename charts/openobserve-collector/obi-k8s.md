# eBPF tracing for the openobserve-collector chart

Status: implemented in chart 0.6.0 and tested on k3s (see [Test results](#test-results)).

This document describes how the chart traces selected workloads with eBPF. It
uses the `obi` receiver (OpenTelemetry eBPF Instrumentation) that ships in the
contrib collector image the chart already uses. Applications need no code changes,
SDKs or restarts.

The same receiver is used by the Linux host install script in
[openobserve/agents](https://github.com/openobserve/agents) (`obi.md` there).
This chart keeps that script's choices where they carry over, and departs from them
where Kubernetes needs something else. The departures are:

- the receiver runs in its own DaemonSet, not in the existing collector
  ([The DaemonSet](#the-daemonset));
- there is no `--service-name` counterpart ([Service names](#service-names));
- OBI's built-in rule for processes that already export OTLP is kept. It limits,
  but does not prevent, duplicate spans. The Linux script has no such rule; both
  tell users not to select apps that send their own traces;
- `docker-proxy` is not excluded; it does not run on Kubernetes nodes.

## Summary

- A new, separate DaemonSet runs only the `obi` receiver. It is off by default
  (`ebpf.enabled: false`). The existing agent and gateway are unchanged.
- What gets traced is chosen with values that mirror the Linux script's flags:
  ports, executable paths and command lines.
- Spans go through the gateway, like SDK spans from the chart's `Instrumentation`
  resources, so a gateway `servicegraph` connector, if you add one, covers eBPF-traced services too. With
  the gateway disabled they go straight to OpenObserve. Spans from processes on the
  node itself, outside any pod, are dropped.
- Traced processes add a W3C `traceparent` header to outgoing plain-text HTTP
  requests (`context_propagation: headers`), so traces continue across pods and
  nodes.
- With eBPF enabled, the OpenTelemetry Operator must be v0.142.0 or later. That
  release's `OpenTelemetryCollector` CRD has `spec.hostPID`, which the receiver
  needs. With eBPF disabled, the chart renders the same resources as before.
- The Go eBPF `Instrumentation` resource (`openobserve-go`) is deprecated in favour
  of this.

## Versions

| Component | Version | Notes |
|---|---|---|
| Collector image | contrib 0.163.1 | already the chart's `appVersion` |
| `obi` receiver | OBI v0.15.2 | bundled in that image |
| OpenTelemetry Operator | v0.142.0 or later, when eBPF is enabled | v0.142.0 added `spec.hostPID`; tested with v0.161.0 |
| Chart | 0.5.1 → 0.6.0 | new feature |

## Values

```yaml
ebpf:
  enabled: false
  trace:
    ports: []        # ports and ranges, e.g. [8080, "9000-9100"]
    exePaths: []     # executable path globs, e.g. ["/app/checkout*"]
    cmdLines: []     # command-line globs, e.g. ["*reports.py*"]
  nodeSelector: {}
  affinity:          # the receiver is built for Linux on amd64 and arm64 only
    nodeAffinity:
      requiredDuringSchedulingIgnoredDuringExecution:
        nodeSelectorTerms:
          - matchExpressions:
              - {key: kubernetes.io/os, operator: In, values: [linux]}
              - {key: kubernetes.io/arch, operator: In, values: [amd64, arm64]}
  tolerations:
    - operator: Exists
  resources: {}
  memoryLimiter:
    check_interval: 1s
    limit_mib: 512
    spike_limit_mib: 128
```

How the values map to the Linux script:

| Linux flag | Chart value |
|---|---|
| `--trace-ports` | `ebpf.trace.ports` |
| `--trace-exe` | `ebpf.trace.exePaths` |
| `--trace-cmd` | `ebpf.trace.cmdLines` |
| `--service-name` | none; see [Service names](#service-names) |

Rules for combining them:

- Each non-empty list among `ports`, `exePaths` and `cmdLines` becomes one include
  rule. A process is traced if it matches any of them.
- With `ebpf.enabled: true`, all three lists empty and `ebpf.network.enabled: false`,
  the chart fails to render. There is no "trace everything" default, matching the Linux
  script, where tracing is on only when a `--trace-*` flag is given.

Validation in the template, with the same limits as the Linux script:

- Each port is a number or a range between 1 and 65535. Plain numbers may be
  given unquoted; ranges are strings.
- Globs must be non-empty strings and may not contain `,`, `{` or `}`. OBI joins a list into one `{a,b}`
  pattern, so these characters would change its meaning. The template quotes
  every glob it writes, since an unquoted leading `*` is a YAML alias.

The Linux script's selection caveats apply unchanged (see its `obi.md`). The ones
that matter most here:

- A port matches any process holding a local socket on it, not only servers.
  Ranges that reach into the ephemeral range (32768–60999 by default) also match
  clients.
- Don't select apps that already send their own traces through an OpenTelemetry
  SDK. See `already-instrumented` under
  [Receiver configuration](#receiver-configuration) for how far OBI limits the
  duplicates.
- Port, executable and command-line rules also match processes on the node itself,
  outside any pod, since `hostPID` makes them visible. Their spans are dropped (see
  [Where spans go](#where-spans-go)), but OBI still instruments them. A common port
  such as 8080 can also match many pods.
- Child processes are traced with their parent.
- OBI injects an agent into every Java and Node.js process it matches, so broad
  selectors are invasive.

Not included, to keep the first version small: namespace, pod label, annotation and
Deployment-name selectors, and a raw `rules` override. OBI v0.15.2 supports all of
them (`match.kubernetes.namespace_glob`, `pod_labels`, `pod_annotations`,
`metadata_glob`), so each
can be added later without changing the design.

## The DaemonSet

The DaemonSet is a new `OpenTelemetryCollector` CR in `mode: daemonset`, named
`<fullname>-ebpf`, rendered from `templates/ebpf.yaml`. Like the agent and gateway
CRs, it sets `managementState` from the chart-wide value. It is not part of the
agent, unlike the Linux script, which adds the receiver to the existing collector.
The reason is failure isolation:

- The receiver runs with `enforce_system_capabilities: true`. On a node that cannot
  run it (no BTF, old kernel, missing capabilities), the receiver fails at start-up
  and the collector exits. Inside the agent, that would also stop logs and metrics
  on that node. In a separate DaemonSet, only tracing is lost there.
- The agent stays unprivileged. Only the eBPF pods need `hostPID` and `privileged`.
- The eBPF pods can be scheduled onto a subset of nodes with their own
  `nodeSelector` and `tolerations`.

The CR uses the chart's service account, like the agent and gateway, so it gets the
chart's ClusterRole. OBI needs it to look up pods (see
[Receiver configuration](#receiver-configuration)). With
`serviceAccount.create: false`, the chart renders no ClusterRole, and the supplied
service account must be granted list and watch on pods, services and nodes.

Pod settings:

| Setting | Value | Why |
|---|---|---|
| `hostPID` | `true` | OBI only sees processes in its own PID namespace and those nested under it |
| `securityContext.privileged` | `true` | needs `BPF`, `PERFMON`, `SYS_PTRACE`, `NET_ADMIN` and others; Go header injection also needs `SYS_ADMIN` |
| `securityContext.runAsUser` | `0` | capabilities added to a non-root container do not reach the process |
| hostPath `/sys/fs/cgroup` | mounted at `/sys/fs/cgroup` | see below |
| hostPath `/sys/kernel/security` | read-only | OBI reads the kernel lockdown mode here |
| hostPath `/sys/kernel/tracing` | read-only | OBI attaches tracepoints through tracefs; see [Context propagation](#context-propagation) |

The cgroup mount matters for propagation. OBI attaches its socket program to the
cgroup v2 root it finds at `/sys/fs/cgroup`. Inside a pod with a private cgroup
namespace, that is the pod's own cgroup, which contains no application sockets.
Propagation then silently does nothing. Mounting the host's `/sys/fs/cgroup` there
avoids this.

Test 4 found the mount unnecessary on k3s with containerd: the privileged pod
already sees the host's cgroup v2 hierarchy at `/sys/fs/cgroup`, and traces joined
across nodes without it. The mount stays, since it is harmless there and other
runtimes were not tested.

The release namespace must allow privileged pods under Pod Security Admission
(`pod-security.kubernetes.io/enforce: privileged`). The agent's hostPath mount of
`/` already requires more than the `baseline` level. On OpenShift, the chart's
service account needs the `privileged` SCC, as the agent's values comments already
describe.

`/sys/fs/bpf` is not mounted. OBI only uses it to pin maps for features this design
doesn't use, and falls back to unpinned maps with a warning. Mounting the host's
bpffs would leave pins on the host that could collide with another OBI install.

## Receiver configuration

The template generates the receiver from `ebpf.trace`. For
`ports: [8080]` and `cmdLines: ["*reports.py*"]`:

```yaml
receivers:
  obi:
    version: "2.0"
    safety:
      enforce_system_capabilities: true
    engine:
      propagation:
        context_propagation: headers
    policy:
      default_action: exclude
      match_order: first_match_wins
    rules:
      - action: exclude
        name: collectors
        match:
          process:
            exe_path_glob: ["*/obi", "obi", "*otelcol", "*otelcol-contrib", "*otelcol-contrib[!/]*"]
      - action: exclude
        name: system-namespaces
        match:
          kubernetes:
            namespace_glob:
              - kube-system
              - kube-node-lease
              - local-path-storage
              - cert-manager
              - monitoring
              - gatekeeper-system
              - gke-connect
              - gke-gmp-system
              - gke-managed-cim
              - gke-managed-filestorecsi
              - gke-managed-metrics-server
              - gke-managed-system
              - gke-system
              - gke-managed-volumepopulator
      - action: exclude
        name: already-instrumented
        match:
          process:
            exports_otlp:
              port: 4317
              protocol: protobuf
      - action: include
        name: ports
        match:
          process:
            open_ports: "8080"
      - action: include
        name: cmd
        match:
          process:
            cmd_args_glob: ["*reports.py*"]
```

Details that are easy to get wrong:

- `version` must be the string `"2.0"`. An unquoted `2.0` is rejected.
- `default_action: exclude` must be written out. When `rules` are given, OBI does
  not infer it, and its default is `include`.
- Custom `rules` replace OBI's built-in ones: the exclusions for collectors and
  OBI itself, for system namespaces and for processes that export OTLP. The three
  exclude rules above restore them with OBI v0.15.2's own lists. Excluded
  namespaces can't be traced even if selected. `first_match_wins` requires excludes before includes.
- `already-instrumented` only stops OBI from *exporting* spans for a process once it
  sees that process export OTLP itself. OBI still instruments the process, and still
  injects its own agent into a JVM or Node.js process that already carries an SDK
  agent. Detection needs an HTTP path ending in `/v1/traces`, or the gRPC
  `TraceService/Export` call, seen in plain text or through OBI's TLS hooks
  (OpenSSL, Go). Exports through a TLS library OBI doesn't hook (such as rustls),
  and exports that get an error response, are missed; an export that gets no
  response at all still counts.
  The `port: 4317` is only used for gRPC exporters with no
  `OTEL_EXPORTER_OTLP_ENDPOINT` set. Spans from before the first export are still
  sent. The rule must stand alone in its exclude rule. OBI keeps this knowledge in
  memory only, so after every eBPF pod restart it sends the process's spans again
  until the process next exports (about 7 seconds in test 7). If the process can't
  export at all, for example while the gateway is down, OBI keeps sending its spans.
  - It covers apps instrumented through the chart's Java, Node.js, Python and .NET
    `Instrumentation` resources: they run inside the app's process and export plain
    HTTP to the gateway.
  - It does not cover the Go one; see [Deprecating the Go `Instrumentation`
    resource](#deprecating-the-go-instrumentation-resource).
- OBI holds back a process running in a container until it has found the
  container's pod through its informers. If they can't list pods (for example, a
  service account without the RBAC above), containerised processes are never
  traced. Only processes on the node itself still match, and their spans are
  dropped. The pod stays `Running`. Test 12 recorded the log: repeated `Failed to
  watch ... pods is forbidden` errors (also for nodes and services), then after 30
  seconds `Kubernetes cache has not been synced after timeout. Processes running in
  containers are not instrumented until their Pod is known.`
- A process whose cgroup layout OBI doesn't recognise is treated as a process on
  the node, so the system-namespace exclusion doesn't apply to it.

The pipeline:

```yaml
processors:
  filter/node_processes:
    error_mode: ignore
    traces:
      span:
        - resource.attributes["k8s.pod.uid"] == nil
exporters:
  otlphttp/gateway:
    endpoint: http://<fullname>-gateway-collector.<namespace>.svc.<clusterDomain>:4318
service:
  pipelines:
    traces:
      receivers: [obi]
      processors: [memory_limiter, filter/node_processes, attributes, batch]
      exporters: [otlphttp/gateway]   # otlphttp/openobserve when gateway.enabled is false
```

The template defines these processors itself: `filter/node_processes` drops spans
from processes outside any pod (see [Where spans go](#where-spans-go)), `attributes`
is the same `k8s_cluster` insert the agent template injects, and `batch` uses the
agent's settings. `otlphttp/gateway` uses the same gateway address as the
`Instrumentation` resources.
`memory_limiter` is set from `ebpf.memoryLimiter`, which defaults to the agent's
values (`check_interval: 1s`, `limit_mib: 512`, `spike_limit_mib: 128`). It takes
fixed sizes rather than percentages because the host's `/sys/fs/cgroup` is mounted
over the container's, so the processor would read the host's memory limit instead
of the pod's. The pipeline has no `k8sattributes`, for the reason in the next section.
It has no `resourcedetection` either: OBI sets `k8s.node.name` and the other
`k8s.*` attributes itself.

`memory_limiter` measures the whole collector process, which includes OBI. Each eBPF
pod also watches every pod, service and node in the cluster; the receiver can't
restrict that to its own node. On large clusters, memory use and API server load
grow with cluster size. `ebpf.resources` is left for users to set, as for the
agent; whoever raises its memory limit should raise `ebpf.memoryLimiter.limit_mib`
with it.

Test 13, on a two-node cluster at about 8 spans/s: each eBPF pod used 350–456 MiB
(`kubectl top`), while the collector process's RSS was about 305 MB with a 45 MB Go
heap. The gap is most likely eBPF maps, which the kernel charges to the pod's cgroup
but `memory_limiter` doesn't see. A memory limit for the eBPF pods should therefore
be at least 768 Mi, well above `limit_mib`. The gateway used about the same
memory with and without eBPF spans at that rate (131 and 135 MiB).

## Service names

OBI looks up Kubernetes metadata itself and names each traced container in this
order:

1. `OTEL_SERVICE_NAME` in the process's environment, or `service.name` in its
   `OTEL_RESOURCE_ATTRIBUTES`
2. the same two variables set in the pod spec
3. the pod annotation `resource.opentelemetry.io/service.name`
4. the pod labels `app.kubernetes.io/instance`, then `app.kubernetes.io/name`
5. the top owner's name (Deployment, StatefulSet, DaemonSet, ...), else the pod
   name

It also sets the `k8s.*` resource attributes (namespace, pod UID and name, owner,
node), so the eBPF pipeline doesn't need `k8sattributes`.

One mismatch to document: the agent and gateway set `service.name` from the
`app.kubernetes.io/name` label only, while OBI tries `app.kubernetes.io/instance`
first. For an app installed by Helm, OBI's spans can carry the release name while
its SDK spans and logs carry the chart name.

The Linux script's `--service-name` has no counterpart. One name per machine suits a
host running one application. A node runs many unrelated pods, and step 3 already
lets each one choose its own name.

## Where spans go

Spans go through the gateway, the route SDK spans from the chart's `Instrumentation`
resources already take. The reason is the gateway's `servicegraph` connector, which
the chart ran by default when this was written (0.7.0 turned it off): it only sees
spans that pass through it. With eBPF spans sent straight to OpenObserve,
services traced only by OBI would be missing from the service graph, and so would
calls between an OBI-traced service and an SDK-instrumented one. Covering services
nobody instrumented is what OBI is for.

The gateway also runs `k8sattributes`, which only fills attributes that are
missing, so it doesn't replace OBI's `service.name`. It finds the pod by
`k8s.pod.uid` first, which OBI sets on spans from pods.

Spans from processes on the node itself have no `k8s.*` attributes. The gateway
would fall back to the sending connection's IP, which is the eBPF collector pod's,
and label them with that pod. The eBPF pipeline therefore drops every span without
`k8s.pod.uid` before it leaves the node. This also drops spans from a containerised
process whose cgroup layout OBI doesn't recognise, since OBI treats it as a process
on the node. Removing the gateway's `from: connection` association instead would
affect every other OTLP sender that relies on it.

`servicegraph` builds an edge by matching a client span to its server span in the
same trace. Edges between nodes therefore depend on [context
propagation](#context-propagation); where it breaks, the two calls land in separate
traces and the edge is missing.

The connector also matches spans per gateway replica (`store.ttl: 30s`). With more
than one replica and no trace-ID load balancing in front, client and server spans
can reach different replicas and the edge is lost. This applies to SDK spans
already; OBI on every node makes it more likely, since it sends far more spans.
The gateway defaults to one replica, so every node's eBPF spans reach one pod; test
13 records its memory use with eBPF spans. Size it with `gateway.resources`.
`gateway.autoscaler` adds replicas, with the edge loss above.

The eBPF collector exports to the gateway in plain-text OTLP/HTTP inside the
cluster, as the SDK instrumentation does. The `collectors` exclude rule keeps OBI
from tracing the eBPF collector, so its own exports produce no spans.

With `gateway.enabled: false`, spans go straight to OpenObserve through
`otlphttp/openobserve`, bypassing any gateway `servicegraph` connector.

Test 11 confirmed this route. Spans from pods kept OBI's `service.name` and
`k8s.*` attributes; the gateway added `k8s.app.instance`, `k8s.pod.ip`,
`k8s.replicaset.uid`, `k8s.cluster.uid` and the container image attributes. OBI
sets `k8s.cluster.name` to an empty string, since it can't discover the name and
the receiver accepts no setting for it (`enrich` is rejected in receiver mode, and
`OTEL_EBPF_KUBE_CLUSTER_NAME` is not read). The chart's own `k8s_cluster` attribute
carries the cluster name, as on all other telemetry. Spans
from a process on the node were all dropped by `filter/node_processes`. The service
graph had edges between OBI-traced services on different nodes
(`client="fe-instance", server="backend-annot"` for a Go front end, and
`client="pyfe"` for a Python one once tracefs was mounted).

## Failure behaviour

The Linux script fails hard: if tracing fails, it stops and disables the collector.
In the chart, failure is per node:

- An unsupported kernel or missing BTF always makes the receiver fail at
  start-up. With `enforce_system_capabilities: true`, so do missing capabilities.
  The collector exits and the pod goes into `CrashLoopBackOff` on that node. Other
  nodes, and the agent on the same node, are unaffected.
- Failures after start-up don't stop the collector. The receiver runs OBI in the
  background and only reports its error at shutdown, so a failure such as being
  unable to load the process-event watcher leaves the pod `Running` and tracing
  nothing. The Linux script catches these by scanning the journal after a restart;
  the chart has no step that runs after the pods start. Test 9 could not make the
  process-event watcher fail after start-up: it loads only at start, and a failure
  there logs `Unable to load eBPF watcher for process events`. A later failure it
  did produce (the collector out of file descriptors) left the pod `Running`, the
  new process untraced, and only a misleading `failed to open
  /sys/kernel/security/lockdown ... too many open files` warning in the log.
  Restarting the pod recovered it.

The default `ebpf.affinity` keeps the DaemonSet off nodes the receiver isn't built
for: non-Linux nodes and architectures other than amd64 and arm64. Use
`ebpf.nodeSelector` to keep it off Linux nodes that can't run it, such as those
with old kernels.

### Operator version

An operator older than v0.142.0 does not know `spec.hostPID`. Depending on how the
CR is applied, the field is either rejected with an error or dropped. If it is
dropped, the pod starts without the host PID namespace and traces nothing, without
an error. `helm template` and GitOps tools render without a cluster, so the chart
can't check the CRD. Mitigations:

- `README.md` installs operator v0.161.0 and states v0.142.0 as the minimum for eBPF.
- `NOTES.txt` states the minimum when `ebpf.enabled` is true.

Test 10 on v0.136.0:

| Client | `spec.hostPID` |
|---|---|
| `helm install` / `helm upgrade` (Helm 3, client-side apply) | dropped; Helm only prints `Warning: unknown field "spec.hostPID"` (nothing on an upgrade of an existing CR) |
| `kubectl apply`, `kubectl create`, server-side apply | rejected |

With the field dropped, the eBPF pods run 1/1 with no errors and no `instrumenting
process` log lines, and no spans arrive. Upgrading the operator afterwards does not
bring the field back: a plain `helm upgrade` leaves the stored CR as it is. Use
`helm upgrade --force` (`--force-replace` on Helm 4), or delete the eBPF CR and
upgrade. `UPGRADING.md` and `docs/traces.md` say so.

## Context propagation

`headers` mode makes traced processes add `traceparent` to outgoing HTTP/1 and
HTTP/2 requests in plain text. Go processes also get it over TLS, except on nodes
with kernel lockdown enabled (Secure Boot). Incoming `traceparent` headers are read
too, so a call from a traced pod to a traced pod on another node lands in one
trace.

Known limits, the same as on Linux:

- No header on other TLS traffic. Traces across HTTPS between non-Go services
  break into separate traces.
- On kernels before 6.4, keep-alive connections opened before OBI started carry no
  header until they reconnect.
- On kernels with a known `FIONREAD` bug (kernel commit 929e30f93125, carried by
  Ubuntu 6.8), OBI compensates by attaching two `ioctl` syscall tracepoints, which
  needs tracefs. Without the `/sys/kernel/tracing` mount it turns propagation off
  for non-Go processes and logs `context propagation is disabled: the BPF
  compensation is ineffective`. Go processes keep propagating, by another route.
  With the mount it logs `FIONREAD compensation verified`. Found by test 3.
- OBI only looks for `traceparent` in the first 1 KiB of a request.

Within one node, OBI links calls between two traced processes without headers.

## Deprecating the Go `Instrumentation` resource

The chart renders an `Instrumentation` resource named `openobserve-go`. It injects
a privileged eBPF sidecar into pods annotated
`instrumentation.opentelemetry.io/inject-go`, and only works when the operator has
Go instrumentation enabled (`--enable-go-instrumentation` or
`ENABLE_GO_AUTO_INSTRUMENTATION=true`; off by default). The eBPF DaemonSet covers the same Go services
without a sidecar, operator flag or annotation.

To migrate a pod, remove the annotation and select the app with `ebpf.trace`: its
port, executable path or command line.

The security trade-off changes: the sidecar runs privileged only in pods that opt
in, while the DaemonSet runs a privileged pod on every selected node, whatever it
traces.

In 0.6.0:

- `openobserve-go` and `autoinstrumentation.goImageVersion` keep working and are
  marked deprecated in `values.yaml`, `docs/traces.md` and `UPGRADING.md`.
- Don't select pods that use it with `ebpf.trace`. The `already-instrumented` rule
  does not help here: the sidecar exports OTLP, not the Go process, so OBI would
  trace the Go process alongside the sidecar and spans would be duplicated.

A later release removes them. The Java, Node.js, Python and .NET resources are
unaffected.

## Network flows

Added in chart 0.8.0. `ebpf.network.enabled: true` makes the same receiver also
export `obi.network.flow.bytes`: bytes between workloads, for any TCP or UDP
protocol, for a cluster dependency map. It works with or without `ebpf.trace`
selectors. With none, the receiver keeps only the three exclude rules, so OBI
instruments no process, and the template renders no traces pipeline.

The template adds to the receiver:

```yaml
network:
  capture:
    enabled: true
metrics:
  features: [network]
```

and a metrics pipeline:

```yaml
metrics:
  receivers: [obi]
  processors: [memory_limiter, attributes, batch]
  exporters: [otlphttp/gateway]   # otlphttp/openobserve when gateway.enabled is false
```

- `metrics.features: [network]` is explicit so OBI doesn't also send application
  metrics for traced processes.
- `filter/node_processes` is not in the metrics pipeline: flow metrics carry no
  `k8s.pod.uid`, and flows to and from nodes are wanted.
- The pods run with `hostNetwork: true`, so OBI sees the node's interfaces and not
  only the pod's. The operator then sets `dnsPolicy: ClusterFirstWithHostNet`, so
  the gateway's `*.svc` address still resolves. The collector's own metrics are bound to
  `127.0.0.1:8888` (`service.telemetry`), not the node's addresses, so they aren't
  reachable from other pods or hosts; port 8888 must still be free on the node's
  loopback, and the operator's `-monitoring` Service for it gets connection refused.
- No RBAC changes: OBI resolves owners from the pods, services and nodes it already
  watches.
- OBI's default labels only: direction, source and destination owner name and type,
  and namespace. Pod names, addresses and ports are off, which keeps the number of
  series low (about 290 series on the test cluster). The receiver in OBI v0.15.2
  can't change the label set. `k8s.cluster.name` may be empty: OBI reads it only
  from eksctl, AKS or Cluster API node labels, so it was empty on k3s; the chart's `k8s_cluster` label is there instead.
- The same bytes are reported more than once: by both nodes for traffic between
  nodes, and on the client's node once against the Service and once against the
  workload behind it. Which workloads talk is exact; byte totals are only exact when
  either workload's pods all run on one node, or summed over the `Service` rows for
  traffic sent to a Service. See
  [docs/metrics.md](docs/metrics.md#13-ebpf-network-flows).

## Security considerations

- The eBPF pods are privileged and share the host PID namespace. They can read the
  memory and network traffic of every process on the node. Anyone who can change
  the DaemonSet, its image or its configuration effectively has root on every
  node it runs on. That is the same trust level the agent's hostPath mount of `/`
  already requires, but the DaemonSet should be documented as such.
- With the gateway enabled, the eBPF collector holds no OpenObserve credentials.
  Only with `gateway.enabled: false` does its config carry the
  `otlphttp/openobserve` exporter and its `Authorization` header.
- Spans include HTTP methods, full URL paths and status codes, and query strings.
  OBI redacts values of query parameters with known sensitive names, but not
  paths: a token carried in a path (`/reset/<token>`) or in an unrecognised
  parameter ends up in OpenObserve, readable by anyone who can read the traces.
  This matches what OpenTelemetry SDK instrumentation records, so the pipeline does
  not strip URL attributes. Don't select apps that put secrets in URLs.
- No RBAC changes. OBI would also read Secrets and ConfigMaps referenced by a
  container's `OTEL_SERVICE_NAME` through `valueFrom`. The ClusterRole grants
  ConfigMaps but not Secrets, and this design does not add Secrets. Such a service
  name is then resolved from a later step in the naming order.

## Files to change

| File | Change |
|---|---|
| `templates/ebpf.yaml` | new: the eBPF `OpenTelemetryCollector` |
| `values.yaml` | new `ebpf` block; deprecation note on `goImageVersion` |
| `templates/NOTES.txt` | operator minimum and selection summary when `ebpf.enabled`; mark the Go injection annotation deprecated |
| `README.md` | pin the operator to v0.161.0; eBPF section |
| `docs/traces.md` | eBPF section; Go `Instrumentation` deprecation; correct the operator install text, which says `opentelemetry-operator.enabled: true` installs the operator (the chart has no such dependency) |
| `Chart.yaml` | version 0.6.0 |
| `UPGRADING.md` (repo root) | 0.6.0 entry: operator minimum, Go deprecation |
| `.helmignore` | exclude this design document from the packaged chart |
| `opentelemetry-operator.yaml` (repo root) | replace with the v0.161.0 manifest, keeping the `--enable-go-instrumentation` arg the current copy adds (v0.161.0 enables nginx instrumentation through an env var itself) |

## Test plan

Run on multipass VMs on one of the Mac minis: a two-node k3s cluster on Ubuntu
24.04 (kernel 6.8, BTF, cgroup v2), with cert-manager, the operator at v0.161.0, and
the chart installed from the branch. Both VMs sit on the same mini, so the nodes can
reach each other. Spans go to a self-hosted OpenObserve.

| # | Test | Pass condition |
|---|---|---|
| 1 | `helm template` with `ebpf.enabled` and no selectors; bad port; glob with `,` | each fails with a clear message |
| 2 | Install with `ebpf.trace.ports` on a test app | spans arrive; `service.name` follows the naming order |
| 3 | A front end on node 1 calls a back end on node 2, both traced | one trace across both nodes |
| 4 | Test 3 without the `/sys/fs/cgroup` mount | confirms whether the mount is needed |
| 5 | Install with `ebpf.trace.exePaths` on one app and `cmdLines` on another | both traced (rules combine with OR) |
| 6 | Collector pods and `kube-system`, with a selector that matches them | none traced |
| 7 | An app instrumented through the operator's Java `Instrumentation`, selected by `ebpf.trace` | record spans before and after its first export; the app stays healthy with both agents loaded |
| 8 | A node without BTF, or with capabilities removed | that node's eBPF pod crash-loops; agent and other nodes unaffected |
| 9 | A failure after start-up (e.g. block the process-event watcher) | the pod stays `Running`; record the log message for the docs |
| 10 | Operator v0.136.0 | record the symptom for the docs |
| 11 | Spans through the gateway, from a pod and from a process on the node; test 3's apps; then `gateway.enabled: false` | pod spans keep OBI's `service.name` and `k8s.*` attributes; node-process spans are dropped; the service graph has an edge between test 3's front end and back end; with the gateway disabled, spans reach OpenObserve directly |
| 12 | RBAC removed from the service account | the warning is logged; record it for the docs |
| 13 | Memory use of an eBPF pod, and of the gateway with and without eBPF spans | recorded, to guide `ebpf.resources` and the gateway's sizing |
| 14 | `ebpf.enabled: false` (default) | rendered output identical to chart 0.5.1 apart from the version |
| 15 | The new operator manifest, with a pod annotated `inject-go` | the operator starts; Go injection still works |

## Test results

Run on 2026-10-18 on two Multipass VMs on one Mac mini: k3s v1.36.5, Ubuntu 24.04,
kernel 6.8.0-142 arm64, BTF, cgroup v2, no lockdown, operator v0.161.0,
cert-manager v1.21.2, and a self-hosted OpenObserve.

| # | Result |
|---|---|
| 1 | Pass. Each bad input fails with a message naming the value |
| 2 | Pass. `service.name` followed the naming order: env var, annotation over labels, `instance` label over `name` label, owner name |
| 3 | Pass, after adding the `/sys/kernel/tracing` mount. Without it, Go traces joined across nodes but Python traces didn't |
| 4 | The `/sys/fs/cgroup` mount isn't needed on k3s with containerd; kept |
| 5 | Pass |
| 6 | Pass. No spans from collectors, `kube-system` or the collector namespace. OBI instrumented host processes (`k3s`, `systemd-resolved`) on selected ports; their spans were dropped |
| 7 | Pass. Both Java agents loaded and the app stayed healthy; OBI's spans stopped once the SDK exported (26 s of duplicates), and come back for a few seconds after each eBPF pod restart |
| 8 | Pass for missing capabilities: that node's pod crash-looped with `the following capabilities are required: ...`; the agent and the other node were unaffected. No node without BTF was available |
| 9 | Partial; see [Failure behaviour](#failure-behaviour) |
| 10 | Recorded; see [Operator version](#operator-version) |
| 11 | Pass; see [Where spans go](#where-spans-go) |
| 12 | Recorded; see [Receiver configuration](#receiver-configuration) |
| 13 | Recorded; see [Receiver configuration](#receiver-configuration) |
| 14 | Pass. Only the chart version label and one NOTES line differ |
| 15 | Pass. The operator starts with `--enable-go-instrumentation`, and an `inject-go` pod got the sidecar and sent spans |

### Network flows

Run on 2026-10-29 on the same cluster (chart 0.8.0), sending to a self-hosted
OpenObserve through the gateway. Test traffic: a curl loop to nginx and a
`redis-cli` loop to Redis, clients in one namespace on one node, servers in another
namespace on the other node.

| # | Test | Result |
|---|---|---|
| N1 | `helm template` with `ebpf.network.enabled` false, against chart 0.7.0 | Pass. Identical apart from the chart version label with eBPF off, and with tracing on for ports, exe paths and command lines |
| N2 | `helm template`: network only; network and tracing; neither | Pass. Network only renders no include rules and no traces pipeline; neither still fails, now also naming `ebpf.network.enabled` |
| N3 | Install network only | Pass. Pods `Running` on both nodes, `hostNetwork: true`, `dnsPolicy: ClusterFirstWithHostNet`; no errors in the logs |
| N4 | Flow metrics in OpenObserve | Pass. Stream `obi_network_flow_bytes`; owners and namespaces set for both the HTTP and the Redis flows, e.g. `netcli/cacheclient` (Deployment) to `netsrv/cache` (Deployment), `direction=request`. DNS to CoreDNS shows as `direction=unknown`. Outside addresses have empty owners; host processes and host-network pods show as `Node` with the node name |
| N5 | Double counting | Each cross-node flow came from both nodes, and the client's node reported it against both the Service and the Deployment: three series with the same rate. The query in docs/metrics.md returns it once (each test workload ran on one node) |
| N6 | No application metrics | Pass. OBI sent no RED metrics with tracing on |
| N7 | DNS to the gateway under `hostNetwork` | Pass. Metrics and spans reached the gateway by its `*.svc` name |
| N8 | Memory (`kubectl top`) | Network only: 82 MiB per eBPF pod. Network and tracing: 377 and 448 MiB, within the 350-456 MiB of tracing alone (test 13) |
| N9 | Tracing with network on | Pass. Spans from all six test services, `k8s.*` attributes from the traced pods, and 226 traces spanning both nodes in 15 minutes |
| N10 | Port clashes | None. Only port 8888 is bound on the node, and nothing else used it |
| N11 | Collector metrics on loopback | Pass. `ss` shows only `127.0.0.1:8888` on both nodes; `curl` to each node IP on 8888 is refused from the other node and from the host; `127.0.0.1:8888/metrics` answers on the node; flows and spans still arrive |

### Network flows, multi-service

Run on 2026-10-29 on the same cluster, network and tracing on, with services in
four namespaces and the `api` pods on both nodes.

| Check | Result |
|---|---|
| Edges | Pass. All 6 edges across the 4 namespaces correct; owner types seen: `Deployment`, `StatefulSet`, `CronJob`, `Job`, `DaemonSet`, `Pod`, `Node`, `Service`. Jobs whose names contain a `-` show as a `CronJob` (see [docs/metrics.md](docs/metrics.md#13-ebpf-network-flows)) |
| Bytes, client on one node | `max` 203.0 MB for 200 MB sent (exact) |
| Bytes, clients on both nodes | `max` 158.9 MB (0.78x), `sum` 310.4 MB (1.53x); the `Service` rows summed: 202.0 MB |
| Series | 417 over 15 minutes |
| Memory | eBPF pods 458-466 MiB with network and tracing; gateway 196-215 MiB |
| Upgrade | Pass. `helm upgrade --reset-then-reuse-values --set ebpf.enabled=true --set ebpf.network.enabled=true` (Helm 3.22.1) kept the existing trace selectors |

## References

- OBI source at tag v0.15.2:
  https://github.com/open-telemetry/opentelemetry-ebpf-instrumentation/tree/v0.15.2
- OpenTelemetry Operator v0.161.0:
  https://github.com/open-telemetry/opentelemetry-operator/releases/tag/v0.161.0
- Linux host install script and its design notes:
  https://github.com/openobserve/agents
