# openobserve-collector helm chart

OpenObserve collector is an opinionated helm chart for deploying the OpenObserve collector that allows to you to:

- Deploy the OpenObserve collector to a Kubernetes cluster
- Capture logs and metrics from the cluster and send it to OpenObserve cloud or a self hosted installation
- Configure auto-instrumentation in your cluster to capture traces from your applications written in following languages (Java, .Net, nodejs, python and Go )

## Prerequisites

### cert-manager

cert-manager is required to be installed in the cluster. If you already have cert-manager installed then you can skip this step. You can install cert-manager using the following command:

```bash
kubectl apply -f https://github.com/cert-manager/cert-manager/releases/download/v1.13.1/cert-manager.yaml
```

Official documentation can be found at https://cert-manager.io/docs/installation/

Wait for 2 minutes after installing cert-manger for the webhook to be ready before installing OpenTelemetry operator.

### OpenTelemetry operator

If you already have OpenTelemetry operator installed then you can skip this step.

```bash
kubectl apply -f https://github.com/open-telemetry/opentelemetry-operator/releases/latest/download/opentelemetry-operator.yaml
```

Official documentation can be found at https://opentelemetry.io/docs/kubernetes/operator/

## Installing the Chart

```bash
helm install o1 . --namespace openobserve-collector --create-namespace --wait
```
