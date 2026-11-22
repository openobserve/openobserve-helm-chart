# OpenObserve Helm Chart

## Amazon EKS

openobserve uses [IRSA](https://docs.aws.amazon.com/eks/latest/userguide/iam-roles-for-service-accounts.html) on Amazon EKS to securely access s3.

You must set a minimum of 2 values:

1. S3 bucket where data will be stored
   - config.ZO_S3_BUCKET_NAME
1. IAM role for the serviceAccount to gain AWS IAM credentials to access s3
   - serviceAccount.annotations."eks.amazonaws.com/role-arn"

## Installation

Install the Cloud Native PostgreSQL Operator. This is a prerequisite for openobserve helm chart. This helm chart sets up a postgres database cluster (1 primary + 1 replica) and uses it as metadata store of OpenObserve.
```shell
kubectl apply --server-side -f \
  https://raw.githubusercontent.com/cloudnative-pg/cloudnative-pg/release-1.30/releases/cnpg-1.30.0.yaml
```

Install the openobserve helm chart
```shell
helm repo add openobserve https://charts.openobserve.ai
helm repo update

kubectl create ns openobserve

helm --namespace openobserve -f values.yaml install o2 openobserve/openobserve
```

## Uninstall

```shell
helm --namespace openobserve delete o2
```

## Enterprise Features

### O2 AI (AI-Powered Operations)

O2 AI is an enterprise-only feature that enables AI-powered operations and intelligent troubleshooting capabilities in OpenObserve.

#### Prerequisites

1. **Enterprise License**: O2 AI is only available with OpenObserve Enterprise
2. **API Key**: You need an API key from one of the supported AI providers (OpenAI, Anthropic, Gemini, etc.)

#### Configuration

To enable O2 AI, set the following values in your `values.yaml`:

```yaml
enterprise:
  enabled: true
  parameters:
    O2_AI_ENABLED: "true"  # Enable AI features
  o2ai:
    enabled: true  # Deploy O2 AI (required when O2_AI_ENABLED is true)
    config:
      O2_AI_MODEL: "claude-sonnet-4-6"  # Or your preferred model
      O2_AI_PROVIDER: "anthropic"  # Options: openai, anthropic, gemini, etc.

auth:
  O2_AI_API_KEY: "your-api-key-here"  # Your AI provider API key
  O2_MCP_USERNAME: "root@example.com"  # MCP authentication (optional)
  O2_MCP_PASSWORD: "your-password"  # MCP authentication (optional)
```

#### Cluster Access (kubectl)

O2 AI can execute `kubectl`, `aws`, `az`, `git`, and `gh` commands against the local cluster. This is disabled by default. When enabled, a dedicated ServiceAccount, ClusterRole, and ClusterRoleBinding are created and the pod mounts a CLI config at `/app/config.yaml`.

```yaml
enterprise:
  o2ai:
    clusterAccess:
      enabled: true
```

**IRSA on AWS EKS** — annotate the ServiceAccount with an IAM role so the pod can also run `aws` CLI commands:

```yaml
enterprise:
  o2ai:
    clusterAccess:
      enabled: true
      serviceAccount:
        annotations:
          eks.amazonaws.com/role-arn: arn:aws:iam::ACCOUNT_ID:role/ROLE_NAME
```

**GKE Workload Identity**:

```yaml
enterprise:
  o2ai:
    clusterAccess:
      enabled: true
      serviceAccount:
        annotations:
          iam.gke.io/gcp-service-account: SA_NAME@PROJECT_ID.iam.gserviceaccount.com
```

**Custom RBAC rules** — override the default ClusterRole rules (read/write on pods, deployments, services, etc.):

```yaml
enterprise:
  o2ai:
    clusterAccess:
      enabled: true
      rbac:
        rules:
          - apiGroups: [""]
            resources: ["pods", "services", "namespaces"]
            verbs: ["get", "list", "watch"]
```

**Custom CLI config** — override which commands the agent is allowed to run:

```yaml
enterprise:
  o2ai:
    cliConfig:
      clis:
        kubectl:
          command: kubectl
          allowed_subcommands: ["get", "describe", "logs"]
          timeout_seconds: 30
          description: "Read-only kubectl access"
    clusterAccess:
      enabled: true
```

#### Using AI Gateway

If you have an AI Gateway deployed (e.g., Envoy Gateway with AI routing), you can configure O2 AI to route through it:

```yaml
aiGateway:
  enabled: true
  gatewayServiceName: "ai-gateway"
  gatewayNamespace: "gateway-namespace"  # Leave empty to use release namespace
  port: 80
```

When using an AI Gateway, you don't need to specify `O2_AI_PROVIDER` as the gateway handles routing based on the model header.

**Deploy Envoy Gateway and AI Gateway**: For instructions on deploying Envoy Gateway with AI routing capabilities, rate limiting, and metrics blocking, see: [https://github.com/openobserve/o2-envoy-gateway](https://github.com/openobserve/o2-envoy-gateway)

#### Internal Secret Between OpenObserve and O2 AI (optional)

Set `auth.O2_AI_INTERNAL_SECRET` to make O2 AI accept incident root-cause-analysis (`sre-rca`) requests only from callers that present a shared secret:

```yaml
auth:
  O2_AI_INTERNAL_SECRET: "<random value, e.g. from: openssl rand -hex 32>"
```

When set, the value is stored in the chart's Secret and the same value is given to both sides:

- the O2 AI container as `O2_INTERNAL_API_SECRET`: it rejects `sre-rca` requests with 401 unless the `x-o2-internal-secret` header matches
- every OpenObserve component as `O2_AI_INTERNAL_SECRET`: it sends that header on `sre-rca` calls

This is opt-in and empty by default, in which case nothing is set on either side. Only enable it with an OpenObserve image that sends the `x-o2-internal-secret` header; an older image would get 401 from the agent and incident RCA would stop working. Once it is set, you can also make O2 AI refuse to start without the secret:

```yaml
enterprise:
  o2ai:
    extraEnv:
      - name: O2_REQUIRE_INTERNAL_SECRET
        value: "true"
```

Setting or changing the value through `auth.O2_AI_INTERNAL_SECRET` restarts O2 AI and the OpenObserve pods together, because each pod template carries a checksum of it, so both sides switch at the same time. With `externalSecret.enabled: true` the chart cannot see the value, so after adding or rotating the key run `kubectl rollout restart` on O2 AI and every OpenObserve workload, otherwise pods that started earlier keep the old value and `sre-rca` calls get 401.

With `externalSecret.enabled: true`, add an `O2_AI_INTERNAL_SECRET` key to your external secret instead; both sides pick it up from there, and nothing is set while the key is absent. `auth.O2_AI_INTERNAL_SECRET` is ignored in that mode.

#### Important Notes

- **Validation**: The deployment will fail if `O2_AI_ENABLED` is set to `"true"` but `enterprise.o2ai.enabled` is not `true`
- **Resource Requirements**: O2 AI requires additional resources. Default requests are 256Mi memory and 250m CPU
- **Scaling**: O2 AI supports horizontal pod autoscaling when needed

### Service Graph

Visualize service dependencies and interactions. OpenObserve builds the service graph from ingested traces on the server side (on by default), so you do not need the OpenTelemetry `servicegraph` connector in your collector. If both write for the same organization, the service graph page uses only OpenObserve's series, but your own PromQL over `traces_service_graph_*` counts requests twice unless it matches `trace_stream`.

```yaml
enterprise:
  parameters:
    O2_SERVICE_GRAPH_ENABLED: "true"
    O2_SERVICE_GRAPH_INTERVAL_SECS: "60"
    O2_SERVICE_GRAPH_FLUSH_SECS: "60"
```

Only data older than `ZO_CACHE_DELAY_SECS` (default 300) is rolled up, so new edges show up after that delay.

### Incidents Management

Enable intelligent incident detection and root cause analysis:

```yaml
enterprise:
  parameters:
    O2_INCIDENTS_ENABLED: "true"
    O2_INCIDENTS_RCA_ENABLED: "true"  # Root Cause Analysis
    O2_INCIDENTS_ALERT_GRAPH_ENABLED: "true"
```

### Service Streams

Advanced correlation and pattern detection:

```yaml
enterprise:
  parameters:
    O2_SERVICE_STREAMS_ENABLED: "true"
    O2_SERVICE_STREAMS_SAMPLE_EVERY_NTH_STREAM: "5"
```

### OpenFGA (permission checks)

With `enterprise.openfga.enabled: true` the chart deploys OpenFGA, pinned to `openfga/openfga:v1.22.1`, with two replicas, a `PodDisruptionBudget` (`minAvailable: 1`), a surge-only rollout (`maxSurge: 1`, `maxUnavailable: 0`) and a preferred spread across nodes. OpenFGA is CPU-bound, so each pod requests 500m CPU and may burst to 2.

```yaml
enterprise:
  openfga:
    image:
      tag: v1.22.1
    listTestedTags: [v1.22.1]
    replicas: 2
    requestTimeoutMs: 5000        # OPENFGA_REQUEST_TIMEOUT=5000ms
    listObjectsDeadlineMs: 5000   # OPENFGA_LIST_OBJECTS_DEADLINE=5000ms
    datastore:
      maxOpenConns: 30            # per replica
      maxIdleConns: 10
    caches:
      checkQuery: false
      checkIterator: false
      cacheController: false
resources:
  openfga:
    requests: { cpu: 500m, memory: 256Mi }
    limits: { cpu: "2", memory: 1Gi }
```

| Value | Meaning |
|---|---|
| `requestTimeoutMs` | OpenFGA request timeout in milliseconds. Rendering fails below 3000, including 0. OpenObserve gets `O2_OPENFGA_REQUEST_TIMEOUT_MS` = this + 1000. |
| `listObjectsDeadlineMs` | OpenFGA list deadline in milliseconds. Rendering fails below 3000 and above `requestTimeoutMs + 3000`, because OpenFGA refuses to start with such a value. |
| `listTestedTags` | Image tags whose list behaviour was tested. Only for these does the chart declare `O2_OPENFGA_LIST_SERVER_DEADLINE_MS` = `min(requestTimeoutMs, listObjectsDeadlineMs)` to OpenObserve. The match is exact on the whole `image.tag` string: a digest-pinned tag such as `v1.22.1@sha256:...` must be listed with its digest. With any other tag OpenObserve keeps checking objects one by one. |
| `datastore.maxOpenConns` | Postgres connections per replica. A rollout briefly adds one pod, so (`replicas` + 1) x `maxOpenConns` plus the OpenObserve pool must stay below Postgres `max_connections`. |
| `resources.openfga` | Helm merges a partial override over the default requests and limits. Set both, or remove one with `null`, so requests never exceed limits. |
| `caches.*` | OpenFGA server caches. They stay off: a cached answer can outlive a revoked permission by several seconds. |

The declared list deadline must never be above the deadline the OpenFGA server really applies. A declaration above the real server deadline lets truncated lists through, so users can miss objects they are allowed to see. Change the two timeouts through these values, never by setting `OPENFGA_*` variables on the OpenFGA pod directly.

**An OpenFGA the chart does not deploy.** The chart always points OpenObserve at its own OpenFGA service. To use another OpenFGA server, keep `enterprise.openfga.enabled: true` and override the config map keys through `extraEnv`; an `env` entry on the container wins over the config map:

```yaml
extraEnv:
  - name: O2_OPENFGA_BASE_URL
    value: http://openfga.example.internal:8080
  # The server's effective list deadline: min(its request timeout, its list deadline), in ms.
  - name: O2_OPENFGA_LIST_SERVER_DEADLINE_MS
    value: "5000"
```

If you do not know that server's deadline, do not add `O2_OPENFGA_LIST_SERVER_DEADLINE_MS`; set `enterprise.openfga.listTestedTags: []` instead, so the config map declares none and OpenObserve checks objects one by one. Otherwise the config map still declares the deadline of the chart's own OpenFGA. The chart still deploys its own OpenFGA in this setup, unused.

**Alerts.** `examples/alerts/openfga-authz.yaml` holds example Prometheus rules for permission-check failures, calls per request and Check latency. The chart does not install them. Test them with `promtool test rules examples/alerts/openfga-authz.test.yaml`.

## Envoy Gateway Integration

OpenObserve provides deep integration with Envoy Gateway for enterprise-grade traffic management, security, and observability.

### Deploy O2 Envoy Gateway

For production deployments, we recommend using O2 Envoy Gateway which provides:
- **AI Traffic Routing**: Intelligent routing to OpenAI, Anthropic, Gemini, and other AI providers
- **Rate Limiting**: Protect your endpoints from abuse
- **Metrics Blocking**: Control access to metrics endpoints
- **TLS Termination**: Automatic certificate management
- **Advanced Load Balancing**: Sophisticated traffic distribution
- **Observability**: Deep insights into API traffic

Deploy O2 Envoy Gateway: [https://github.com/openobserve/o2-envoy-gateway](https://github.com/openobserve/o2-envoy-gateway)

### Configuration

Once Envoy Gateway is deployed, configure OpenObserve to use it:

```yaml
gateway:
  enabled: true
  certificates:
    enabled: true  # Requires cert-manager
    issuerRef:
      name: "letsencrypt-prod"
      kind: "ClusterIssuer"
    certs:
      - name: my-cert
        namespace: gateway-namespace
        secretName: my-tls-secret
        dnsNames:
          - api.example.com
  httpRoutes:
    routes:
      - name: openobserve-api
        gateways:
          - my-gateway
        hostnames:
          - api.example.com
        rules:
          - matches:
              - path:
                  type: PathPrefix
                  value: /
            backendRefs:
              - name: o2-openobserve-router
                port: 5080
```

# Development

If you are developing this chart then you should clone the repo and make any modifications.

You can generate output of the chart using below command to verify:

```shell
helm -n openobserve template o2 . > o2.yaml
```

You can then install using:

```shell
helm -n openobserve install o2 .
```

To upgrade

```shell
helm -n openobserve upgrade o2 .
```

To uninstall

```shell
helm -n openobserve uninstall o2 
```
