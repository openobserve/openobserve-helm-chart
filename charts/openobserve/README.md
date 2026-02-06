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
kubectl apply -f \
  https://raw.githubusercontent.com/cloudnative-pg/cloudnative-pg/release-1.22/releases/cnpg-1.22.1.yaml
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

### SRE Agent (AI-Powered Operations)

The SRE Agent is an enterprise-only feature that enables AI-powered operations and intelligent troubleshooting capabilities in OpenObserve.

#### Prerequisites

1. **Enterprise License**: SRE Agent is only available with OpenObserve Enterprise
2. **API Key**: You need an API key from one of the supported AI providers (OpenAI, Anthropic, Gemini, etc.)

#### Configuration

To enable the SRE Agent, set the following values in your `values.yaml`:

```yaml
enterprise:
  enabled: true
  parameters:
    O2_AI_ENABLED: "true"  # Enable AI features
  sreagent:
    enabled: true  # Deploy SRE Agent (required when O2_AI_ENABLED is true)
    config:
      O2_AI_MODEL: "claude-3-5-sonnet-20241022"  # Or your preferred model
      O2_AI_PROVIDER: "anthropic"  # Options: openai, anthropic, gemini, etc.

auth:
  O2_AI_API_KEY: "your-api-key-here"  # Your AI provider API key
  O2_MCP_USERNAME: "root@example.com"  # MCP authentication (optional)
  O2_MCP_PASSWORD: "your-password"  # MCP authentication (optional)
```

#### Using AI Gateway

If you have an AI Gateway deployed (e.g., Envoy Gateway with AI routing), you can configure the SRE Agent to route through it:

```yaml
aiGateway:
  enabled: true
  gatewayServiceName: "ai-gateway"
  gatewayNamespace: "gateway-namespace"  # Leave empty to use release namespace
  port: 80
```

When using an AI Gateway, you don't need to specify `O2_AI_PROVIDER` as the gateway handles routing based on the model header.

**Deploy Envoy Gateway and AI Gateway**: For instructions on deploying Envoy Gateway with AI routing capabilities, rate limiting, and metrics blocking, see: [https://github.com/openobserve/o2-envoy-gateway](https://github.com/openobserve/o2-envoy-gateway)

#### Important Notes

- **Validation**: The deployment will fail if `O2_AI_ENABLED` is set to `"true"` but `enterprise.sreagent.enabled` is not `true`
- **Resource Requirements**: The SRE Agent requires additional resources. Default requests are 256Mi memory and 250m CPU
- **Scaling**: The SRE Agent supports horizontal pod autoscaling when needed

### Service Graph

Visualize service dependencies and interactions:

```yaml
enterprise:
  parameters:
    O2_SERVICE_GRAPH_ENABLED: "true"
    O2_SERVICE_GRAPH_PROCESSING_INTERVAL_SECS: "300"
```

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
