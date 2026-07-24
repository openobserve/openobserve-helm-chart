# OpenObserve helm charts

Following charts are available in this repository:

- [openobserve](charts/openobserve/README.md)
- [openobserve-standalone](charts/openobserve-standalone/README.md)
- [openobserve-collector](charts/openobserve-collector/README.md)


Add the repository to your helm installation:

```bash
helm repo add openobserve https://charts.openobserve.ai
helm repo update
```

To see the available charts in this repository:

```bash
helm search repo openobserve
```

## Deriving the collector Authorization header (CI/CD)

The `openobserve-collector` chart needs an `Authorization` header to ship data to
OpenObserve. You do **not** need to log into the UI to get it — OpenObserve ingestion uses
HTTP Basic auth built from the same root credentials you pass to the `openobserve` chart, so
you can compute it in your pipeline:

```bash
# Same values you set as auth.ZO_ROOT_USER_EMAIL / auth.ZO_ROOT_USER_PASSWORD
AUTH_HEADER="Basic $(printf '%s:%s' "$ZO_ROOT_USER_EMAIL" "$ZO_ROOT_USER_PASSWORD" | base64 | tr -d '\n')"

helm upgrade --install o2c openobserve/openobserve-collector \
  --set exporters."otlphttp/openobserve".endpoint="$O2_ENDPOINT" \
  --set exporters."otlphttp/openobserve".headers.Authorization="$AUTH_HEADER"
```

## Upgrading

See [UPGRADING.md](UPGRADING.md) for version-specific upgrade notes and breaking changes.
