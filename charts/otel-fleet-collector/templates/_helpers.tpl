{{/*
Expand the name of the chart.
*/}}
{{- define "otel-fleet-collector.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
We truncate at 63 chars because some Kubernetes name fields are limited to this (by the DNS naming spec).
If release name contains chart name it will be used as a full name.
*/}}
{{- define "otel-fleet-collector.fullname" -}}
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
{{- define "otel-fleet-collector.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "otel-fleet-collector.labels" -}}
helm.sh/chart: {{ include "otel-fleet-collector.chart" . }}
{{ include "otel-fleet-collector.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
Selector labels
*/}}
{{- define "otel-fleet-collector.selectorLabels" -}}
app.kubernetes.io/name: {{ include "otel-fleet-collector.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
Create the name of the service account to use
*/}}
{{- define "otel-fleet-collector.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default (include "otel-fleet-collector.fullname" .) .Values.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.serviceAccount.name }}
{{- end }}
{{- end }}

{{/*
Name of the Secret holding the enrollment token.
*/}}
{{- define "otel-fleet-collector.secretName" -}}
{{- if .Values.opamp.existingSecret }}
{{- .Values.opamp.existingSecret }}
{{- else }}
{{- include "otel-fleet-collector.fullname" . }}
{{- end }}
{{- end }}

{{/*
Key of the enrollment token inside that Secret.
*/}}
{{- define "otel-fleet-collector.secretKey" -}}
{{- if .Values.opamp.existingSecret }}
{{- .Values.opamp.existingSecretKey | default "token" }}
{{- else }}
{{- "token" }}
{{- end }}
{{- end }}

{{/*
The OpAMP endpoint, validated: a ws(s):// or http(s):// URL ending in /v1/opamp.
*/}}
{{- define "otel-fleet-collector.opampEndpoint" -}}
{{- $ep := .Values.opamp.endpoint | default "" | trimSuffix "/" }}
{{- if not $ep }}
{{- fail "opamp.endpoint is required, e.g. --set opamp.endpoint=ws://openobserve:5080/api/default/v1/opamp" }}
{{- end }}
{{- if not (regexMatch "^(wss?|https?)://[^/]+(/.*)?/api/[^/]+/v1/opamp$" $ep) }}
{{- fail (printf "opamp.endpoint %q must look like ws://<host>:<port>/api/<org>/v1/opamp (or wss://)" $ep) }}
{{- end }}
{{- $ep }}
{{- end }}

{{/*
The OpenObserve API base for the collector (O2_ENDPOINT): the OpAMP endpoint without /v1/opamp,
with ws:// -> http:// and wss:// -> https://.
*/}}
{{- define "otel-fleet-collector.o2Endpoint" -}}
{{- $base := include "otel-fleet-collector.opampEndpoint" . | trimSuffix "/v1/opamp" }}
{{- regexReplaceAll "^ws" $base "http" }}
{{- end }}

{{/*
Whether supervisor.yaml gets tls.insecure: true. Mirrors the Docker install command, which sets it
whenever the server is not https, plus the explicit opamp.insecureTls switch.
*/}}
{{- define "otel-fleet-collector.insecureTls" -}}
{{- $ep := include "otel-fleet-collector.opampEndpoint" . }}
{{- if or .Values.opamp.insecureTls (not (or (hasPrefix "wss://" $ep) (hasPrefix "https://" $ep))) }}true{{- end }}
{{- end }}

{{/*
Pod security context. Reading node log files needs root (they are root-owned and not
world-readable), so with hostLogs.enabled the pod runs as uid/gid 0.
*/}}
{{- define "otel-fleet-collector.podSecurityContext" -}}
{{- $ctx := deepCopy (.Values.podSecurityContext | default dict) }}
{{- if .Values.hostLogs.enabled }}
{{- $ctx = mustMergeOverwrite $ctx (dict "runAsUser" 0 "runAsGroup" 0 "runAsNonRoot" false) }}
{{- end }}
{{- toYaml $ctx }}
{{- end }}

{{/*
Supervisor container security context. With hostLogs.enabled, DAC_READ_SEARCH is added so
root can read the root-owned log files; nothing else changes.
*/}}
{{- define "otel-fleet-collector.securityContext" -}}
{{- $ctx := deepCopy (.Values.securityContext | default dict) }}
{{- if .Values.hostLogs.enabled }}
{{- $caps := $ctx.capabilities | default dict }}
{{- $add := $caps.add | default list }}
{{- if not (has "DAC_READ_SEARCH" $add) }}
{{- $add = append $add "DAC_READ_SEARCH" }}
{{- end }}
{{- $_ := set $caps "add" $add }}
{{- $_ := set $ctx "capabilities" $caps }}
{{- end }}
{{- toYaml $ctx }}
{{- end }}
