# openobserve helm chart

## Amazon EKS

By default standalone openobserve uses local disk as a storage. You can configure persistence storage or s3 storage.

Openobserve uses [IRSA](https://docs.aws.amazon.com/eks/latest/userguide/iam-roles-for-service-accounts.html) on Amazon EKS to securely access s3.

You must set a minimum of 2 values:

1. S3 bucket where data will be stored
   - config.ZO_S3_BUCKET_NAME
1. IAM role for the serviceAccount to gain AWS IAM credentials to access s3
   - serviceAccount.annotations."eks.amazonaws.com/role-arn"

## Install

```shell
helm repo add openobserve https://charts.openobserve.ai
helm repo update

kubectl create ns openobserve

helm --namespace openobserve -f values.yaml install o2 openobserve/openobserve-standalone
```

## Uninstall

```shell
helm delete o2
```

## Enterprise Features

### SRE Agent (AI-Powered Operations)

The SRE Agent is an enterprise-only feature that enables AI-powered operations and intelligent troubleshooting capabilities in OpenObserve Standalone.

#### Prerequisites

1. **Enterprise License**: SRE Agent is only available with OpenObserve Enterprise
2. **API Key**: You need an API key from one of the supported AI providers (OpenAI, Anthropic, Gemini, etc.)

#### Configuration

To enable the SRE Agent in standalone mode, set the following values in your `values.yaml`:

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

**Note**: In standalone mode, the SRE Agent always runs with a single replica.

#### Using AI Gateway

If you have an AI Gateway deployed (e.g., Envoy Gateway with AI routing), you can configure the SRE Agent to route through it:

```yaml
aiGateway:
  enabled: true
  gatewayServiceName: "ai-gateway"
  gatewayNamespace: "gateway-namespace"  # Leave empty to use release namespace
  port: 80
```

**Deploy Envoy Gateway and AI Gateway**: For instructions on deploying Envoy Gateway with AI routing capabilities, rate limiting, and metrics blocking, see: [https://github.com/openobserve/o2-envoy-gateway](https://github.com/openobserve/o2-envoy-gateway)

#### Important Notes

- **Validation**: The deployment will fail if `O2_AI_ENABLED` is set to `"true"` but `enterprise.sreagent.enabled` is not `true`
- **Single Replica**: Unlike the distributed chart, the standalone SRE Agent always runs with 1 replica (no autoscaling)
- **Resource Requirements**: Default requests are 256Mi memory and 250m CPU

### Other Enterprise Features

The standalone chart also supports the following enterprise features:

- **Service Graph**: Visualize service dependencies
- **Incidents Management**: Intelligent incident detection and RCA
- **Service Streams**: Advanced correlation and pattern detection

Configuration is the same as the distributed chart - see the main chart documentation for details.

## Envoy Gateway Integration

OpenObserve Standalone provides seamless integration with Envoy Gateway for enterprise-grade traffic management and security.

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

Once Envoy Gateway is deployed, configure OpenObserve Standalone to use it:

```yaml
gateway:
  enabled: true
  httpRoutes:
    routes:
      - name: openobserve-ui
        gateways:
          - my-gateway
        hostnames:
          - ui.example.com
        rules:
          - matches:
              - path:
                  type: PathPrefix
                  value: /
            backendRefs:
              # Use the full service name for standalone
              - name: o2-openobserve-standalone
                port: 5080
```

**Important**: For standalone deployments, ensure the `backendRefs.name` matches your actual service name (typically `{{ release-name }}-openobserve-standalone`).

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
helm -n openobserve uninstall o2 .
```
