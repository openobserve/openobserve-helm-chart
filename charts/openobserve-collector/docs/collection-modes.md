# Kubernetes Object Collection Modes

The `k8sobjects` receiver supports two modes for collecting Kubernetes object state: **watch** and **pull**. This document explains how each mode works, what is currently configured and why, and the impact of switching modes.

---

## How the Modes Work

### Watch Mode

```
Collector starts
     │
     ├─ Initial LIST (resourceVersion=0)
     │   → emits all existing objects as ADDED events immediately
     │
     └─ Persistent watch stream kept open
         → every CREATE   → ADDED event
         → every UPDATE   → MODIFIED event
         → every DELETE   → DELETED event
```

- Real-time: changes appear in OpenObserve within seconds
- One persistent HTTP connection per resource type to the API server
- Initial burst on startup (all existing objects arrive at once)
- If the watch stream breaks, the receiver reconnects and re-syncs automatically

### Pull Mode

```
Collector starts
     │
     └─ Waits for interval (e.g. 5m or 10m)
          │
          ├─ Full LIST of all objects → emits all as ADDED events
          ├─ Waits again
          ├─ Full LIST again → emits all again as ADDED events
          └─ ... repeats forever
```

- No real-time updates — changes visible only after the next pull interval
- No persistent connection — one-shot LIST request per interval
- First data appears only **after the first interval elapses** (not on startup)
- Every pull re-sends ALL objects (not just changes) — heavier on the API server for large resource counts
- No DELETE events — removed objects simply stop appearing after the next pull

---

## Current Configuration

### Base Chart (`values.yaml`)

| Resource | Mode | Interval | Reason |
|----------|------|----------|--------|
| Events | watch | — | Real-time event stream is the primary value |
| Pods | watch | — | Pod lifecycle changes must be captured immediately |
| Nodes | watch | — | Node conditions (Ready, Pressure) change and matter immediately |
| Deployments | watch | — | Rollout progress needs real-time tracking |
| DaemonSets | watch | — | Scheduling/readiness changes are time-sensitive |
| StatefulSets | watch | — | Replica and readiness changes need real-time visibility |
| ReplicaSets | watch | — | Owned by deployments; tracks rollout state |
| Services | watch | — | Endpoint changes affect traffic routing |
| Namespaces | watch | — | Namespace lifecycle (terminating) is important |
| PersistentVolumeClaims | watch | — | Binding state changes matter for app availability |
| PersistentVolumes | watch | — | Status transitions (Released, Failed) need tracking |
| Ingresses | watch | — | Routing rule changes need to be captured |
| Jobs | watch | — | Job completion/failure is time-sensitive |
| CronJobs | watch | — | Next schedule and suspend state |
| HPA | watch | — | Scaling decisions happen rapidly |
| StorageClasses | watch | — | Rarely changes but watch is safe |
| ConfigMaps | watch | — | Config changes can affect running apps |
| NetworkPolicies | watch | — | Security-sensitive, changes must be captured fast |
| Endpoints | watch | — | Service discovery changes in real-time |
| LimitRanges | watch | — | Admission control configuration |
| ResourceQuotas | watch | — | Quota usage changes with every pod create/delete |
| ServiceAccounts | watch | — | Security-sensitive: new SA = potential access change |
| Roles | watch | — | Security-sensitive: permission changes must be real-time |
| ClusterRoles | watch | — | Security-sensitive: cluster-wide permission changes |
| RoleBindings | watch | — | Security-sensitive: subject-to-role mapping |
| ClusterRoleBindings | watch | — | Security-sensitive: cluster-wide subject-to-role mapping |
| **CRDs** | **pull** | **5m** | **See below — watch is dangerous for CRDs** |

---

## Why CRDs Are Pull Mode (Special Case)

CRDs are the **only resource that must use pull mode**. Here is what happens with watch mode:

### The problem with watch mode for CRDs

1. Watch mode does an immediate LIST of all existing CRDs on startup
2. A typical cluster has 100–300+ CRDs
3. Each CRD contains a full OpenAPI v3 schema (`spec.versions[*].schema.openAPIV3Schema`) of **100KB to 2MB**
4. The entire batch is sent to OpenObserve in a single HTTP request
5. Result: **HTTP 400** from OpenObserve (request too large)
6. Worse: the oversized batch **corrupts the `k8s_objects` stream schema** — all data in that stream stops being queryable

### How pull mode + strip processor solves this

```
Gateway starts
     │
     ├─ All watch-mode objects stream in (pods, nodes, deployments...)
     │   ← fine, these are small documents
     │
     └─ CRDs: first pull fires after 5 minutes
          │
          ├─ transform/strip_crd_spec processor runs:
          │   ├─ Promotes: crd_group, crd_scope, crd_stored_versions → top level
          │   └─ Deletes: spec (OpenAPI schema), status entirely
          │
          └─ Compact CRD document (~1KB) sent to OpenObserve ✓
```

The 5-minute delay serves two purposes:
- The startup burst from all watch-mode objects has cleared before CRDs arrive
- CRDs change very rarely (only during operator installs/upgrades), so the delay has no practical impact

### If you need to switch CRDs to watch mode

**Do not do this** unless you have a specific requirement and have addressed the schema size problem first. If you must:

1. Ensure `transform/strip_crd_spec` is in the processor chain **before** `batch` — it strips `spec` and `status` to make documents small enough
2. Be aware the initial LIST will still fire immediately on startup and send all CRDs at once — monitor the gateway logs for HTTP 400 errors
3. Increase the batch `timeout` and reduce `send_batch_size` to spread the load:
   ```yaml
   batch:
     send_batch_size: 100      # reduce from 2000
     send_batch_max_size: 200  # reduce from 5000
     timeout: 10s
   ```
4. If the stream schema gets corrupted: delete the `k8s_objects` stream in OpenObserve UI and redeploy the gateway

---

## Impact of Switching Watch → Pull

If you need to convert any watch-mode resource to pull mode (e.g. to reduce API server watch connections on a large cluster):

| Impact | Details |
|--------|---------|
| **Delayed initial data** | First data appears only after the interval elapses (not on startup) |
| **No DELETE events** | Deleted objects are not reported — they simply stop appearing |
| **No real-time updates** | Changes visible only at the next poll interval |
| **Higher API server load** | Full LIST every interval vs streaming deltas with watch |
| **Duplicate ADDED events** | Every pull re-emits all objects as ADDED — queries must use MAX/LAST not SUM |

### Resources where pull mode is acceptable

These resources change infrequently and eventual consistency is tolerable:

| Resource | Suggested interval |
|----------|--------------------|
| CRDs | 5m (current) |
| StorageClasses | 10m |
| LimitRanges | 10m |
| ClusterRoles | 5m |
| ClusterRoleBindings | 5m |

### Resources where pull mode is NOT recommended

| Resource | Reason |
|----------|--------|
| Events | Events are ephemeral (1h TTL) — a 10m poll misses most of them |
| Pods | Pod crashes, restarts, OOMKills must be captured in real-time |
| Nodes | Node NotReady conditions are time-critical for alerting |
| HPA | Scaling events happen in seconds |
| Jobs | Job completion/failure windows can be shorter than the poll interval |
| Endpoints | Service routing changes need to be reflected immediately |
| Roles / RoleBindings | Security: delayed detection of unauthorized permission grants |

---

## Impact of Switching Pull → Watch

If you convert a pull-mode resource to watch mode:

| Impact | Details |
|--------|---------|
| **Immediate initial data** | All existing objects arrive on startup as ADDED events |
| **Real-time DELETE tracking** | Removed objects emit DELETED events |
| **Startup burst risk** | For large resource counts, the initial LIST can be a large batch |
| **Persistent connection** | One additional watch connection to the API server per resource |

For most resources the startup burst is manageable. The exception is CRDs (see above).

---

## Quick Reference

```
watch mode  → real-time, immediate, persistent connection, startup burst
pull mode   → delayed, periodic snapshot, no DELETE events, heavier LIST per interval

Use pull for:  CRDs (mandatory due to size), rarely-changing cluster-scoped resources
Use watch for: everything else, especially security-sensitive and lifecycle-critical resources
```
