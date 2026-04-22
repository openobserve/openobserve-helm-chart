# Kubernetes Object State Collection

The gateway StatefulSet watches the Kubernetes API for object state changes and ships them as structured log documents to OpenObserve.

**OpenObserve streams:**
- `k8s_objects` — all object types below (nodes, deployments, services, etc.)
- `k8s_events` — Kubernetes Events (separate stream, see [logs.md](logs.md))

---

## Collection Mode

Most objects use **watch mode** — the collector opens a persistent watch stream against the Kubernetes API. Every CREATE, UPDATE, and DELETE triggers an event that is immediately shipped. This means OpenObserve always reflects the current state of your cluster.

**Exception: CRDs** use **pull mode** every 5 minutes to avoid the initial LIST flood (all CRDs at once would be a massive batch).

---

## Objects Collected

| Object | API Group | Mode | Stream |
|--------|-----------|------|--------|
| Pods | core | watch | `k8s_objects` (via `logs/k8s_pods` pipeline) |
| Nodes | core | watch | `k8s_objects` |
| Deployments | apps | watch | `k8s_objects` |
| Services | core | watch | `k8s_objects` |
| Namespaces | core | watch | `k8s_objects` |
| PersistentVolumeClaims | core | watch | `k8s_objects` |
| PersistentVolumes | core | watch | `k8s_objects` |
| DaemonSets | apps | watch | `k8s_objects` |
| StatefulSets | apps | watch | `k8s_objects` |
| ReplicaSets | apps | watch | `k8s_objects` |
| Ingresses | networking.k8s.io | watch | `k8s_objects` |
| NetworkPolicies | networking.k8s.io | watch | `k8s_objects` |
| Jobs | batch | watch | `k8s_objects` |
| CronJobs | batch | watch | `k8s_objects` |
| HorizontalPodAutoscalers | autoscaling | watch | `k8s_objects` |
| CustomResourceDefinitions | apiextensions.k8s.io | pull (5m) | `k8s_objects` |
| StorageClasses | storage.k8s.io | watch | `k8s_objects` |
| ConfigMaps | core | watch | `k8s_objects` |
| Endpoints | core | watch | `k8s_objects` |
| ServiceAccounts | core | watch | `k8s_objects` |
| Roles | rbac.authorization.k8s.io | watch | `k8s_objects` |
| ClusterRoles | rbac.authorization.k8s.io | watch | `k8s_objects` |
| RoleBindings | rbac.authorization.k8s.io | watch | `k8s_objects` |
| ClusterRoleBindings | rbac.authorization.k8s.io | watch | `k8s_objects` |
| LimitRanges | core | watch | `k8s_objects` |
| ResourceQuotas | core | watch | `k8s_objects` |

---

## Document Structure

Each object is stored as a JSON document in OpenObserve. The top-level fields match the raw Kubernetes object structure. In **pull mode** (used by default for pods and CRDs), fields are flattened with `body_` prefix:

```
body_kind                        = "Pod"
body_metadata_name               = "nginx-abc123"
body_metadata_namespace          = "production"
body_metadata_creationtimestamp  = "2024-01-01T00:00:00Z"
body_spec_nodename               = "ip-10-0-1-5"
body_status_phase                = "Running"
```

In **watch mode**, fields appear under `body_object_*`:
```
body_object_kind                 = "Pod"
body_object_metadata_name        = "nginx-abc123"
body_type                        = "ADDED" | "MODIFIED" | "DELETED"
```

---

## CRD Special Handling

CRDs contain large OpenAPI v3 schemas (100KB–2MB each). Without stripping, a single CRD batch would cause HTTP 400 from OpenObserve and corrupt the stream schema.

**The `transform/strip_crd_spec` processor** runs before export and:
1. Promotes 3 useful fields to the top level before deleting `spec` and `status`:

| Promoted field | Source | Description |
|----------------|--------|-------------|
| `body.crd_group` | `body.spec.group` | API group (e.g. `cert-manager.io`) |
| `body.crd_scope` | `body.spec.scope` | `Namespaced` or `Cluster` |
| `body.crd_stored_versions` | `body.status.storedVersions` | Active API versions |

2. Deletes `body.spec` and `body.status` entirely for CRDs.

**Resulting fields per CRD document:**

| Field | Example |
|-------|---------|
| `body_kind` | `CustomResourceDefinition` |
| `body_metadata_name` | `certificates.cert-manager.io` |
| `body_metadata_creationtimestamp` | `2024-01-01T00:00:00Z` |
| `body_crd_group` | `cert-manager.io` |
| `body_crd_scope` | `Namespaced` |
| `body_crd_stored_versions` | `["v1"]` |
| `k8s_cluster` | `cluster1` |

To extract the API group from the CRD name in SQL:
```sql
SUBSTRING(body_metadata_name FROM POSITION('.' IN body_metadata_name) + 1)
```

---

## Pods Pipeline

Pods are sent through a **separate pipeline** (`logs/k8s_pods`) to the default stream, while all other objects go to `k8s_objects`. This allows pod state documents and pod logs to be co-located in the same stream for easier correlation.

---

## Resource Attributes Added

The `k8sattributes` processor enriches all object documents with:

| Attribute | Description |
|-----------|-------------|
| `k8s.namespace.name` | Object namespace |
| `k8s.pod.name` | Source pod name (gateway pod) |
| `k8s.node.name` | Node the gateway runs on |
| `k8s.deployment.name` | Deployment owning the gateway |
| `k8s.replicaset.name` | ReplicaSet owning the gateway |
| `k8s.statefulset.name` | StatefulSet name (for gateway itself) |
| `container.image.name` | Gateway container image |
| `container.image.tag` | Gateway container image tag |
| `k8s.cluster.uid` | Cluster UID |
