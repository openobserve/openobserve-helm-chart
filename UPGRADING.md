# Upgrading the OpenObserve Helm charts

This document highlights upgrades that need manual attention. If a chart version is
**not** listed here, upgrading is expected to be a straight `helm upgrade` with no manual
steps. Chart versions follow [Semantic Versioning](https://semver.org/); a bump in the
**major** chart version signals a potentially breaking change to the chart itself.

> Tip: always review the rendered diff before applying an upgrade:
>
> ```bash
> helm diff upgrade <release> openobserve/<chart> -f your-values.yaml   # requires the helm-diff plugin
> ```

## How to read this file

- **App upgrades** — bumping the OpenObserve application (`appVersion`), e.g. `0.9.x → 0.10.x`.
  Application-level breaking changes (schema/meta-store migrations, renamed env vars) are the
  application's own; check the [OpenObserve release notes](https://github.com/openobserve/openobserve/releases).
- **Chart upgrades** — breaking changes to the chart templates/values themselves (renamed
  values, moved keys, renamed resources).

## Chart changes

### openobserve-standalone — Postgres DSN moved to the Secret

`ZO_META_POSTGRES_DSN` is now rendered into the **Secret** instead of the plaintext ConfigMap,
and a new `auth.ZO_META_POSTGRES_DSN` takes precedence over `config.ZO_META_POSTGRES_DSN` when
set. No values change is required — the existing `config.ZO_META_POSTGRES_DSN` is still honored
and the StatefulSet consumes it via `envFrom`. This is transparent on `helm upgrade`.

### openobserve / openobserve-standalone — cert-manager issuer annotation

The default `ingress.annotations` no longer hardcodes `cert-manager.io/issuer: letsencrypt`.
- If you rely on the **built-in** Issuer, set `certIssuer.enabled: true` — the annotation is then
  injected automatically.
- If you use your **own** `cert-manager.io/cluster-issuer`, just set it under `ingress.annotations`;
  there is no longer a conflicting `issuer` annotation.

### openobserve-standalone — persistence.enabled now gates the PVC

`persistence.enabled: false` now actually removes the data `volumeClaimTemplate` and backs `/data`
with an ephemeral `emptyDir`. Previously the PVC was always created. If you were setting
`persistence.enabled: false` and unknowingly still getting a PVC, you will now get ephemeral
storage — set it back to `true` if you need the PVC.

## Application upgrades

For OpenObserve application upgrades (the `appVersion` / image tag), always consult the
upstream release notes for migration steps before upgrading:
<https://github.com/openobserve/openobserve/releases>.
