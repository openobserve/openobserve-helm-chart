{{/*
Expand the name of the chart.
*/}}
{{- define "openobserve.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
We truncate at 63 chars because some Kubernetes name fields are limited to this (by the DNS naming spec).
If release name contains chart name it will be used as a full name.
*/}}
{{- define "openobserve.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- $name := default .Chart.Name .Values.nameOverride }}
{{- if contains $name .Release.Name }}
{{- .Release.Name | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}
{{- end }}

{{/*
Create chart name and version as used by the chart label.
*/}}
{{- define "openobserve.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "openobserve.labels" -}}
helm.sh/chart: {{ include "openobserve.chart" . }}
{{ include "openobserve.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}

{{- $custom := .Values.labels | default dict -}}
{{- range $key, $value := $custom }}
{{ $key }}: {{ $value | quote }}
{{- end }}
{{- end }}

{{/*
{{- end }}

{{/*
Selector labels
*/}}
{{- define "openobserve.selectorLabels" -}}
app.kubernetes.io/name: {{ include "openobserve.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
Create the name of the service account to use
*/}}
{{- define "openobserve.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default (include "openobserve.fullname" .) .Values.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.serviceAccount.name }}
{{- end }}
{{- end }}

{{/*
Name of the dedicated Secret that holds ZO_REPORT_SERVER_SECRET.
*/}}
{{- define "openobserve.reportServerSecretName" -}}
{{- printf "%s-report-server" (include "openobserve.fullname" . | trunc 49 | trimSuffix "-") }}
{{- end }}

{{/*
Effective ZO_REPORT_SERVER_SECRET: the user's value, else the one in the existing dedicated Secret, else a new random one.
*/}}
{{- define "openobserve.reportServerSecret" -}}
{{- if not .Values.auth.ZO_REPORT_SERVER_SECRET -}}
{{- $existing := lookup "v1" "Secret" .Release.Namespace (include "openobserve.reportServerSecretName" .) | default dict -}}
{{- $stored := dig "data" "ZO_REPORT_SERVER_SECRET" "" $existing | b64dec -}}
{{- /* Cached in .Values so every include in one render (Secret and all checksums) sees the same value. */ -}}
{{- $_ := set .Values.auth "ZO_REPORT_SERVER_SECRET" ($stored | default (randAlphaNum 48)) -}}
{{- end -}}
{{- .Values.auth.ZO_REPORT_SERVER_SECRET -}}
{{- end }}

{{/*
Pod annotation that restarts a workload when anything in the chart Secret changes. It hashes the
data of the rendered secret.yaml, so every key is covered, but not its labels, so a chart version
bump alone doesn't restart pods.
*/}}
{{- define "openobserve.secretChecksumAnnotation" -}}
checksum/secret: {{ (include (print .Template.BasePath "/secret.yaml") . | fromYaml).stringData | toJson | sha256sum }}
{{- end }}

{{/*
Status page custom domains: the effective settings as JSON, the chart defaults under whatever the
release supplies. A release upgraded with --reuse-values has no statusPageDomains block, or only the
keys it set, because Helm reuses the old release's values and not the new chart's defaults; every
template reads the block through this helper so that stays "off" instead of failing. Keep the
defaults equal to values.yaml (the render tests compare them).
Usage: {{- $spd := include "openobserve.statusPageDomainsCfg" . | fromJson }}
*/}}
{{- define "openobserve.statusPageDomainsCfg" -}}
{{- $defaults := dict
  "enabled" false
  "target" ""
  "ports" (dict "https" 5443 "http" 5088 "health" 5089)
  "proxyProtocol" (dict "enabled" false "trustedCidrs" (list))
  "probe" "listener"
  "acmeDirectory" ""
  "allowOrgs" (list)
  "denyOrgs" (list)
  "epoch" 1
  "service" (dict "annotations" (dict) "externalTrafficPolicy" "Local" "loadBalancerIP" "" "httpsPort" 443 "httpPort" 80)
  "preStopSeconds" 30
-}}
{{- $c := mustMergeOverwrite $defaults (deepCopy (.Values.statusPageDomains | default dict)) -}}
{{- /* Helm parses --set integers as int64, and the JSON round trip would turn them into float64 and round an epoch above 2^53, so the epoch travels as a decimal string. */ -}}
{{- $e := $c.epoch -}}
{{- if or (kindIs "int64" $e) (kindIs "int" $e) -}}
{{- $_ := set $c "epoch" (printf "%d" (int64 $e)) -}}
{{- else if and (kindIs "float64" $e) (eq (floor $e) $e) -}}
{{- $_ := set $c "epoch" (printf "%.0f" $e) -}}
{{- end -}}
{{- $c | toJson -}}
{{- end }}

{{/*
Name of the status page domain Service. A fullname of up to 46 characters is used as it is. A longer
one is cut to exactly 38 characters and followed by "-" and 8 characters of the hash of the whole
fullname. That 47 character form can never equal an unmodified name, which is at most 46, so a
short release cannot take the name of a shortened one, and the result stays within the 63 characters
Kubernetes allows for a Service. Two releases that differ only after the cut get different hashes.
*/}}
{{- define "openobserve.domainListenerName" -}}
{{- $f := include "openobserve.fullname" . -}}
{{- if le (len $f) 46 -}}
{{- printf "%s-domain-listener" $f -}}
{{- else -}}
{{- printf "%s-%s-domain-listener" ($f | trunc 38) (sha256sum $f | trunc 8) -}}
{{- end -}}
{{- end }}

{{/*
Status page custom domains: fails the render when the feature is on without a target, or with a
malformed setting. The chart holds no domain key: the app reads ZO_STATUS_PAGE_DOMAIN_ENCRYPTION_KEY
or derives it from the master key. Included from configmap.yaml, which the StatefulSet hashes.
*/}}
{{- define "openobserve.statusPageDomainsValidate" -}}
{{- $c := include "openobserve.statusPageDomainsCfg" . | fromJson -}}
{{- if not (has $c.probe (list "listener" "load_balancer")) -}}
{{- fail (printf "statusPageDomains.probe must be \"listener\" or \"load_balancer\", got %q." (toString $c.probe)) -}}
{{- end -}}
{{- if not $c.target -}}
{{- fail "statusPageDomains.target is required when statusPageDomains.enabled is true: set the hostname customers point their CNAME at." -}}
{{- end -}}
{{- /* Whole numbers only: a lossy conversion would turn a malformed value into a different number. */ -}}
{{- $whole := dict "preStopSeconds" $c.preStopSeconds "ports.https" $c.ports.https "ports.http" $c.ports.http "ports.health" $c.ports.health "service.httpsPort" $c.service.httpsPort "service.httpPort" $c.service.httpPort -}}
{{- range $name, $v := $whole -}}
{{- if not (and (kindIs "float64" $v) (eq (floor $v) $v) (ge $v 0.0)) -}}
{{- fail (printf "statusPageDomains.%s must be a non-negative whole number, got %v." $name $v) -}}
{{- end -}}
{{- end -}}
{{- $epoch := toString $c.epoch -}}
{{- if not (regexMatch "^[0-9]+$" $epoch) -}}
{{- fail (printf "statusPageDomains.epoch must be a non-negative whole number, got %v." $c.epoch) -}}
{{- end -}}
{{- /* The setting is a signed 64-bit integer; compare the decimal text, never a float. */ -}}
{{- $digits := regexReplaceAll "^0+" $epoch "" -}}
{{- if or (gt (len $digits) 19) (and (eq (len $digits) 19) (gt $digits "9223372036854775807")) -}}
{{- fail (printf "statusPageDomains.epoch must not exceed 9223372036854775807, got %v." $c.epoch) -}}
{{- end -}}
{{- end }}

{{/*
Container ports of the status page domain listener. The names differ from the main `http` port.
*/}}
{{- define "openobserve.statusPageDomainsPorts" -}}
{{- $c := include "openobserve.statusPageDomainsCfg" . | fromJson -}}
- name: domain-https
  containerPort: {{ int $c.ports.https }}
- name: domain-http
  containerPort: {{ int $c.ports.http }}
- name: domain-health
  containerPort: {{ int $c.ports.health }}
{{- end }}

{{/*
preStop delay of the pod that runs the status page domain listener: it keeps serving until the
load balancer has removed it. statusPageDomainsGracePeriod is the pod grace period that goes with it.
*/}}
{{- define "openobserve.statusPageDomainsLifecycle" -}}
{{- $c := include "openobserve.statusPageDomainsCfg" . | fromJson -}}
lifecycle:
  preStop:
    exec:
      command: ["/bin/sh", "-c", "sleep {{ int $c.preStopSeconds }}"]
{{- end }}

{{- define "openobserve.statusPageDomainsGracePeriod" -}}
{{- $c := include "openobserve.statusPageDomainsCfg" . | fromJson -}}
{{- add (int $c.preStopSeconds) 30 -}}
{{- end }}
