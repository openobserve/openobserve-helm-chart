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

## Status page custom domains

The `statusPageDomains` block turns on built-in TLS, where OpenObserve orders the certificates and a customer proves a domain with a CNAME. The alternative, [proxy mode](#proxy-mode), uses the top-level `extraEnv` instead of this block.

OpenObserve Enterprise can serve a status page on a customer's own hostname with its own TLS listener and its own certificates (ACME, TLS-ALPN-01). `statusPageDomains` turns it on:

```yaml
statusPageDomains:
  enabled: true
  target: domains.example.com      # the installation's base hostname; each customer gets their own name under it
  service:
    annotations: {}                # load balancer annotations; see the recipes in values.yaml
```

Rendering fails when the feature is on without `target`.

The domain key encrypts certificate keys and the CA account key. It is not a chart value, and the chart renders none: the app reads `ZO_STATUS_PAGE_DOMAIN_ENCRYPTION_KEY` (64 random bytes, base64; create one with `openssl rand -base64 64 | tr -d '\n'`), or derives the key from the installation's master key (`O2_MASTER_ENCRYPTION_KEY`). Use one of:

1. Reuse a master key the installation already has; it derives the domain key, so nothing else is needed. With `externalSecret.enabled: false` that is `enterprise.parameters.ZO_MASTER_ENCRYPTION_KEY`. With `externalSecret.enabled: true` the chart ignores that value (the workloads read `externalSecret.name`, not the chart's Secret), so the master key must be in your external Secret as `O2_MASTER_ENCRYPTION_KEY`. A master key you already pass to every pod as `O2_MASTER_ENCRYPTION_KEY` in the top-level `extraEnv` (for example with `valueFrom.secretKeyRef`) is used too, with or without `externalSecret`; OpenObserve reads only the `O2_` name, so an `extraEnv` entry named `ZO_MASTER_ENCRYPTION_KEY` is not a master key. If none of these is set, use option 2.
2. Put `ZO_STATUS_PAGE_DOMAIN_ENCRYPTION_KEY` in the **top-level** `extraEnv` (the root key of `values.yaml`, not a component's `extraEnv`), with `valueFrom.secretKeyRef` to a Secret you create. This also works with `externalSecret.enabled: true`, and it affects nothing but this feature, so prefer it unless a master key already exists:

```yaml
extraEnv:
  - name: ZO_STATUS_PAGE_DOMAIN_ENCRYPTION_KEY
    valueFrom:
      secretKeyRef:
        name: o2-domain-key
        key: ZO_STATUS_PAGE_DOMAIN_ENCRYPTION_KEY
```

Create that Secret first: a pod whose Secret reference has no `optional: true` does not start until the Secret exists. With neither key set, the feature reports `no_key`, and the rest of OpenObserve keeps running; rendering does not fail.

Do not set a master key only for this feature. A master key turns on encryption at rest for the whole installation: at boot OpenObserve re-encrypts the stored secrets with it, an invalid value (it must be 64 random bytes, base64) makes every OpenObserve pod fail at boot, and if you lose the key those secrets cannot be read. If you do mean to set a new master key, read the "openobserve 1.1.3 / openobserve-standalone 1.1.3 — master encryption key reaches OpenObserve" entry of [UPGRADING.md](https://github.com/openobserve/openobserve-helm-chart/blob/main/UPGRADING.md) first: it covers the format, what happens at startup and why to keep the key.

With the feature on, the chart adds the three container ports (`5443` TLS, `5088` redirect, `5089` health), a `preStop` delay with a matching termination grace period (also applied to the router's liveness probe), and a `<release>-openobserve-domain-listener` Service of type `LoadBalancer` for ports 443 and 80 (the name is shortened for long release names). The listener runs on the router pods, and their probes stay on `/healthz` of the main port.

DNS: `target` is the installation's base hostname, not the name a customer points a domain at. Point two records at the load balancer above, `target` and the wildcard `*.<target>` (in the reverse-proxy layout below, at the proxy instead). Each claim has its own CNAME destination, `<label>.<target>`, which the domains dialog shows to the customer; the customer copies that exact name, and a name they pick themselves under the target does not verify. Without the wildcard no certificate is issued. With built-in TLS an apex domain, or a domain behind a CDN that hides the CNAME, cannot be connected; proxy mode takes those.

PROXY protocol: with `proxyProtocol.enabled: true` an empty `trustedCidrs` trusts nothing and every connection is closed. List the load balancer's or proxy's source range, and the pod network as well when `probe` is `listener`.

Supported layouts:

| Layout | Setup |
|---|---|
| Kubernetes with a spare load balancer address | `statusPageDomains.enabled: true`, the target, and the domain key (see above). |
| AWS with the AWS Load Balancer Controller | NLB with IP targets, PROXY protocol v2, health check on the health port, Elastic IPs. Set `proxyProtocol.enabled`, `proxyProtocol.trustedCidrs` and `probe: load_balancer`. |
| AWS with the in-tree controller, or Azure | NLB or Standard Load Balancer with `externalTrafficPolicy: Local`, no PROXY protocol, `probe: listener`. The load balancer checks the node only (see Health checks). |
| A reverse proxy already on 443 that can pass TLS through by SNI (nginx `stream` with `ssl_preread`, HAProxy in TCP mode) | Point `target` and `*.<target>` at the proxy's public address, not at the chart's Service, so the CA and the customers reach the proxy. Pass the target and unknown hostnames through to port `5443` of the router pods with PROXY protocol (version 1 or 2), and set `statusPageDomains.proxyProtocol.enabled: true`: the listener reads that header only when it is on. Set the trusted CIDRs to the proxy's address. The proxy answers port 80 itself with a redirect to HTTPS, so `5088` is not used there. Use `probe: load_balancer` if the cluster can reach the target's public address, otherwise `probe: listener` with the pod network in `trustedCidrs`. The chart still renders the domain Service: give it an internal load balancer annotation or leave it unused. |

Not supported with built-in TLS: one address with an ingress controller on 443, a private CA, an installation the internet cannot reach, an apex domain, or a CDN that hides the CNAME. Use [proxy mode](#proxy-mode) for those; its TXT verification still requires public DNS and outbound DNS from the pods.

Health checks: only the AWS Load Balancer Controller recipe (IP targets) checks the listener itself, by calling the health port of each pod; the Service does not publish that port. The in-tree AWS and Azure recipes check the node only, and a node passes while its router pod is Ready on the main `/healthz`. A router whose listener is not ready can therefore still receive traffic there; the outside check of the installation catches that. Without annotations the Service has no application health check.

When you upgrade a release with `--reuse-values`, the new block is absent from the stored values and the feature stays off; to turn it on, set the keys you need (`enabled`, `target`) and the chart fills in the other defaults.

The annotation recipes for each cloud are in `values.yaml`.

### Proxy mode

Proxy mode is the other way to run custom domains, for self-hosted installations only (OpenObserve Cloud always uses built-in TLS). Your own proxy terminates TLS with its own certificates and forwards to the router's main HTTP port. OpenObserve orders no certificate and opens no domain port. Use it where built-in TLS does not fit: an ingress controller on the only address, a CDN or other proxy that terminates TLS, a private CA, an installation the internet cannot reach, or customers who need an apex domain. It needs an Enterprise build.

**Turn it on.** Leave `statusPageDomains.enabled` false and set `ZO_STATUS_PAGE_DOMAIN_TLS` to `proxy` in the chart's **top-level** `extraEnv` (the root key of `values.yaml`, which reaches every OpenObserve workload). Do not use `router.extraEnv` or another component's `extraEnv`: with a router-only setting, the nodes that verify domains and answer the API still have the mode off, so domains cannot be added or verified.

```yaml
extraEnv:
  - name: ZO_STATUS_PAGE_DOMAIN_TLS
    value: proxy
```

No target, no wildcard record, no key, no domain Service and no extra port are needed. `ZO_STATUS_PAGE_DOMAIN_TARGET` is ignored in proxy mode. Set the mode only after the five items under "What you set up first".

Use the same top-level `extraEnv` for `ZO_HTTP_REAL_IP_SOURCE`, `ZO_STATUS_PAGE_DOMAIN_APP_HOSTS` and `ZO_STATUS_PAGE_DOMAIN_OPERATIONAL_HOSTS`, and for `ZO_STATUS_PAGE_DOMAIN_ALLOW_ORGS` and `ZO_STATUS_PAGE_DOMAIN_DENY_ORGS` if you want org restrictions. `statusPageDomains.allowOrgs` and `statusPageDomains.denyOrgs` are rendered only when `statusPageDomains.enabled` is true, so they have no effect in proxy mode.

**What a customer does.** The customer adds the TXT record the domains dialog shows, `_o2-verify.<their domain>` with the claim's value, and points the domain at your proxy with any record you tell them to use: an A or AAAA record, an apex, a CDN in front, or a CNAME to your proxy's name. The TXT record must stay: a domain without it for 72 hours is released from its page, after an e-mail to the org's admins.

**DNS for TXT verification.** OpenObserve looks up the TXT record using public DNS resolvers, not cluster DNS. Publish it in the domain's public zone and allow outbound DNS to the internet from the OpenObserve pods. This applies even when visitors reach the proxy only on a private network or the proxy uses a private CA. An internal-only TXT record cannot verify the domain.

**What OpenObserve does.** It verifies the TXT record, serves the page for the `Host` your proxy forwards, and applies the same org policy as built-in TLS, so a denied or unlisted org stops being served. It orders no certificate, opens no domain port, and cannot check that the domain is reachable, so the dialog says "Verified", never "Serving".

**What you set up first.** The chart documents this deployment boundary and does not enforce it. Do items 1 to 5 before setting the mode. Once it is on, OpenObserve sorts every request by its `Host`. The host of `ZO_WEB_URL`, the hosts in `ZO_STATUS_PAGE_DOMAIN_APP_HOSTS`, IP literals, `localhost` and the hosts in `ZO_STATUS_PAGE_DOMAIN_OPERATIONAL_HOSTS` keep the app's own routes. Every other authority is a customer hostname: one with a holder gets its status page, and one without gets the not-connected page instead of the app.

1. Give the proxy a certificate and **an explicit route for each customer hostname**, and make it **reject every other authority**, except the app's own if the proxy also fronts the app (a shared ingress): keep an explicit route for each of those too, because rejecting them at the proxy would cut off the UI and API. Catch-all forwarding of arbitrary hostnames is not supported by this release, because OpenObserve does not bound the metadata reads an unknown authority can cause.
2. Forward to the router's main HTTP port (`5080` by default) with the visitor's `Host` unchanged, because the serving path reads `Host` and nothing else. On a customer hostname OpenObserve answers `GET /api/status_pages_public_by_host` (the page data) and `POST /api/status_pages_public_by_host/auth` (the password unlock), and the proxy must forward both. It answers any other GET with the page shell, redirects `/status`-shaped GET paths to `/`, and answers every other method 404.
3. Keep the main HTTP port reachable **only** through the proxy, plus the operational access below. A client that reaches the port directly chooses its own `Host` and its own client-address header, which skips the proxy's route list and its address handling.
4. Set `ZO_HTTP_REAL_IP_SOURCE` to **exactly one** source, the header the proxy controls, and have the proxy overwrite it from its own connection. The default, `XEnvoyExternalAddress,XRealIp,RightmostXForwardedFor`, **must not stay enabled**, because the first header present wins and a client can send any of them. If the proxy cannot be trusted to overwrite one, set it to `ConnectInfo`: all visitors then share one rate-limit bucket, and that limit is the price.
5. Make every authority that serves the UI or API an app authority: its host must be the host of `ZO_WEB_URL` or an entry in `ZO_STATUS_PAGE_DOMAIN_APP_HOSTS`. `config.ZO_WEB_URL` is empty by default and the chart does not derive it from the ingress, so with the default the primary hostname is not an app authority and would get the not-connected page. Either set `config.ZO_WEB_URL` to the primary URL, with the scheme (for example `https://observe.example.com`; a bare hostname there is not parsed as a URL and gives no app host), or list the bare hostname (for example `observe.example.com`, no scheme) in `ZO_STATUS_PAGE_DOMAIN_APP_HOSTS`. List in `ZO_STATUS_PAGE_DOMAIN_APP_HOSTS` any additional app or API authority the installation serves (beyond the host of `ZO_WEB_URL`), and set `ZO_STATUS_PAGE_DOMAIN_OPERATIONAL_HOSTS` to the Service or node names that must keep answering probes and scrapes. Both are comma lists.

**Operational access.** In proxy mode the app's own routes answer for the app authority, its configured aliases, and operational authorities: an IP-literal `Host`, `localhost`, and `ZO_STATUS_PAGE_DOMAIN_OPERATIONAL_HOSTS`. That is what keeps `GET /healthz` from the kubelet on a pod IP and `/metrics` scrapes working. It adds **no** path exemption on a customer hostname: `/healthz`, `/metrics`, `/config` and the app's own `/api/*` routes are not reachable there. The only API paths a customer hostname answers are the two status-page endpoints of item 2, served by the customer-host handler and not by the app's API.

**If this installation already serves custom domains behind your proxy,** then after the upgrade to the minimum version custom domains are off until you set the mode. Existing domains keep being served meanwhile, and none can be added or verified. Once the mode is on, every domain is checked for its TXT record; a domain whose record was removed has 72 hours to get it again, so tell the owners first.

**Changing modes.** Changing between built-in TLS and proxy mode later is a restart of every node and asks every existing domain for the other record, with 72 hours to add it.

The `proxyProtocol` settings are about a TCP proxy in front of the **domain listener** and have nothing to do with proxy mode, whose client address comes from `ZO_HTTP_REAL_IP_SOURCE`.

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
