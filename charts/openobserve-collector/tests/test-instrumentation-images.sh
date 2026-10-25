#!/usr/bin/env bash
set -euo pipefail

chart_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

render_instrumentation() {
  local language="$1"
  shift
  helm template o2c "$chart_dir" \
    --namespace openobserve-collector \
    --show-only "templates/instrumentation-${language}.yaml" \
    --set gateway.enabled=false \
    "$@"
}

assert_image() {
  local language="$1"
  local expected="$2"
  shift 2
  local actual
  actual="$(render_instrumentation "$language" "$@" | sed -n 's/^    image: //p' | tr -d '"')"
  if [[ "$actual" != "$expected" ]]; then
    printf '%s image: expected <%s>, got <%s>\n' "$language" "$expected" "$actual" >&2
    exit 1
  fi
}

assert_image go 'ghcr.io/open-telemetry/opentelemetry-go-instrumentation/autoinstrumentation-go:v0.23.0'
assert_image go 'ghcr.io/open-telemetry/opentelemetry-go-instrumentation/autoinstrumentation-go:v0.24.0' \
  --set-string autoinstrumentation.goImageVersion=v0.24.0

for language in dotnet java nodejs python; do
  assert_image "$language" ''
done

for language in dotnet go java nodejs python; do
  assert_image "$language" "registry.example.com/otel/${language}:v1" \
    --set-string "autoinstrumentation.images.${language}=registry.example.com/otel/${language}:v1"
done
