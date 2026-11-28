{{/*
Per-install credentials.

A pre-install/pre-upgrade hook Job (also an Argo CD PreSync hook) creates the Secret
"<fullname>-generated" (and "<fullname>-postgres-generated" for the bundled Postgres) only when it
is missing, and afterwards only adds keys that are missing. It never changes or deletes a value, and
the Secrets are not part of the release, so "helm uninstall" keeps them.

Pods load "<fullname>-generated" with envFrom before the chart Secret (or externalSecret), so any
value the user sets wins. The chart Secret renders a generated key only when the user set it.
*/}}

{{- define "openobserve.generatedSecretName" -}}
{{- printf "%s-generated" (include "openobserve.fullname" . | trunc 53 | trimSuffix "-") }}
{{- end }}

{{- define "openobserve.postgresGeneratedSecretName" -}}
{{- printf "%s-postgres-generated" (include "openobserve.fullname" . | trunc 44 | trimSuffix "-") }}
{{- end }}

{{- define "openobserve.secretGeneratorName" -}}
{{- printf "%s-secret-generator" (include "openobserve.fullname" . | trunc 46 | trimSuffix "-") }}
{{- end }}

{{/*
Hook annotations for the generator's ServiceAccount, Role, RoleBinding and Job. Argo CD maps the Helm
hooks itself; the explicit Argo CD annotations make the PreSync hook independent of that mapping.
Usage: include "openobserve.secretGeneratorHookAnnotations" (dict "weight" "-10")
*/}}
{{- define "openobserve.secretGeneratorHookAnnotations" -}}
helm.sh/hook: pre-install,pre-upgrade
helm.sh/hook-weight: {{ .weight | quote }}
helm.sh/hook-delete-policy: before-hook-creation,hook-succeeded
argocd.argoproj.io/hook: PreSync
argocd.argoproj.io/sync-wave: {{ .weight | quote }}
argocd.argoproj.io/hook-delete-policy: BeforeHookCreation,HookSucceeded
{{- end }}

{{/*
Which values the hook Job generates, as JSON. A key is generated only when the generator is on and
the user left the value empty. Root user values, the tracing header, the gRPC token, the salt and the
Postgres DSNs are not generated with externalSecret: the external Secret holds them.
Usage: $g := include "openobserve.generatedKeys" . | fromJson
*/}}
{{- define "openobserve.generatedKeys" -}}
{{- $on := .Values.secretGenerator.enabled -}}
{{- $app := and $on (not .Values.externalSecret.enabled) -}}
{{- $dex := and .Values.enterprise.enabled .Values.enterprise.dex.enabled -}}
{{- $client := index (.Values.enterprise.dex.config.staticClients | default (list dict)) 0 | default dict -}}
{{- $pg := .Values.postgres.enabled -}}
{{- $userEmail := .Values.auth.ZO_ROOT_USER_EMAIL -}}
{{- $userPassword := .Values.auth.ZO_ROOT_USER_PASSWORD -}}
{{- $userTracing := .Values.auth.ZO_TRACING_HEADER_VALUE | default .Values.config.ZO_TRACING_HEADER_VALUE -}}
{{- $g := dict
  "any" $on
  "rootEmail" (and $app (not $userEmail))
  "rootPassword" (and $app (not $userPassword))
  "tracing" (and $app (not $userEmail) (not $userPassword) (not $userTracing))
  "grpcToken" (and $app (not .Values.config.ZO_INTERNAL_GRPC_TOKEN))
  "salt" (and $app (not .Values.auth.ZO_EXT_AUTH_SALT))
  "dexClientSecret" (and $on $dex (not $client.secret) (not $client.secretEnv))
  "postgres" (and $on $pg (not .Values.postgres.spec.password))
  "postgresDSN" (and $app $pg (not .Values.postgres.spec.password))
  "pgadmin" (and $on $pg .Values.postgres.pgadmin.enabled (not .Values.postgres.pgadmin.PGADMIN_DEFAULT_PASSWORD))
-}}
{{- toJson $g -}}
{{- end }}

{{/*
envFrom entry for the generated Secret. Goes before the chart Secret / externalSecret so their
values win. Not optional: on a new install pods wait until the hook Job has created it, so no pod
starts without the shared token and salt.
*/}}
{{- define "openobserve.generatedSecretEnvFrom" -}}
{{- if .Values.secretGenerator.enabled -}}
- secretRef:
    name: {{ include "openobserve.generatedSecretName" . }}
{{- end -}}
{{- end }}

{{/*
Explicit env entries for the generated keys of OpenObserve pods, as a YAML list. Explicit env beats
every envFrom source. That matters on upgrade: Helm and Argo CD never remove a key from a live
Secret's data when it disappears from stringData, so the chart Secret of an upgraded release still
holds the old root user, tracing header and (empty) gRPC token. optional: an existing release may
have no value for a key (gRPC token, salt), and then the pod keeps what it had before.
Not used with externalSecret: the external Secret holds these values.
*/}}
{{- define "openobserve.generatedEnv" -}}
{{- $g := include "openobserve.generatedKeys" . | fromJson -}}
{{- $keys := list -}}
{{- if $g.rootEmail }}{{ $keys = concat $keys (list "ZO_ROOT_USER_EMAIL" "ZO_REPORT_USER_EMAIL") }}{{ end -}}
{{- if $g.rootPassword }}{{ $keys = concat $keys (list "ZO_ROOT_USER_PASSWORD" "ZO_REPORT_USER_PASSWORD") }}{{ end -}}
{{- if $g.tracing }}{{ $keys = append $keys "ZO_TRACING_HEADER_VALUE" }}{{ end -}}
{{- if $g.grpcToken }}{{ $keys = append $keys "ZO_INTERNAL_GRPC_TOKEN" }}{{ end -}}
{{- if $g.salt }}{{ $keys = append $keys "ZO_EXT_AUTH_SALT" }}{{ end -}}
{{- if $g.postgresDSN }}{{ $keys = concat $keys (list "ZO_META_POSTGRES_DSN" "ZO_META_POSTGRES_RO_DSN") }}{{ end -}}
{{- if and $g.dexClientSecret (not .Values.externalSecret.enabled) }}{{ $keys = append $keys "O2_DEX_CLIENT_SECRET" }}{{ end -}}
{{- $env := list -}}
{{- range $keys -}}
{{- $env = append $env (dict "name" . "valueFrom" (dict "secretKeyRef" (dict "name" (include "openobserve.generatedSecretName" $) "key" . "optional" true))) -}}
{{- end -}}
{{- toYaml $env -}}
{{- end }}

{{/*
Published defaults that older chart versions shipped. A new install that sets one of them fails;
an upgrade only warns (see NOTES.txt).
*/}}
{{- define "openobserve.publishedDefaults" -}}
{{- toJson (dict
  "ZO_ROOT_USER_EMAIL" (list "root@example.com")
  "ZO_ROOT_USER_PASSWORD" (list "Complexpass#123")
  "ZO_TRACING_HEADER_VALUE" (list "Basic cm9vdEBleGFtcGxlLmNvbTpDb21wbGV4cGFzcyMxMjM=")
  "ZO_EXT_AUTH_SALT" (list "openobserve")
  "O2_DEX_CLIENT_SECRET" (list "example-app-secret" "ZXhhbXBsZS1hcHAtc2VjcmV0")
  "POSTGRES_PASSWORD" (list "Batman123")
  "PGADMIN_DEFAULT_PASSWORD" (list "Batman123")
) -}}
{{- end }}

{{/*
Values the user set in values.yaml that equal a published default, as a JSON list of value paths.
*/}}
{{- define "openobserve.userPublishedDefaults" -}}
{{- $d := include "openobserve.publishedDefaults" . | fromJson -}}
{{- $client := index (.Values.enterprise.dex.config.staticClients | default (list dict)) 0 | default dict -}}
{{- $checks := list
  (list "auth.ZO_ROOT_USER_EMAIL" .Values.auth.ZO_ROOT_USER_EMAIL $d.ZO_ROOT_USER_EMAIL)
  (list "auth.ZO_ROOT_USER_PASSWORD" .Values.auth.ZO_ROOT_USER_PASSWORD $d.ZO_ROOT_USER_PASSWORD)
  (list "auth.ZO_TRACING_HEADER_VALUE" .Values.auth.ZO_TRACING_HEADER_VALUE $d.ZO_TRACING_HEADER_VALUE)
  (list "config.ZO_TRACING_HEADER_VALUE" .Values.config.ZO_TRACING_HEADER_VALUE $d.ZO_TRACING_HEADER_VALUE)
  (list "auth.ZO_EXT_AUTH_SALT" .Values.auth.ZO_EXT_AUTH_SALT $d.ZO_EXT_AUTH_SALT)
  (list "enterprise.dex.config.staticClients[0].secret" $client.secret $d.O2_DEX_CLIENT_SECRET)
  (list "postgres.spec.password" .Values.postgres.spec.password $d.POSTGRES_PASSWORD)
  (list "postgres.pgadmin.PGADMIN_DEFAULT_PASSWORD" .Values.postgres.pgadmin.PGADMIN_DEFAULT_PASSWORD $d.PGADMIN_DEFAULT_PASSWORD)
-}}
{{- $found := list -}}
{{- range $checks -}}
{{- if and (index . 1) (has (toString (index . 1)) (index . 2)) -}}
{{- $found = append $found (index . 0) -}}
{{- end -}}
{{- end -}}
{{- toJson $found -}}
{{- end }}

{{/*
"true" only for a real "helm install" against a cluster where this release has no Secret yet.
"helm template" and Argo CD render without cluster access (lookup returns nothing), so they never
count as a new install here: they get the warning, not the failure.
*/}}
{{- define "openobserve.isLiveNewInstall" -}}
{{- if and .Release.IsInstall (lookup "v1" "ServiceAccount" .Release.Namespace "default") (not (lookup "v1" "Secret" .Release.Namespace (include "openobserve.fullname" .))) -}}
true
{{- end -}}
{{- end }}

{{/*
Render-time checks, included from secret.yaml.
*/}}
{{- define "openobserve.validateSecrets" -}}
{{- $found := include "openobserve.userPublishedDefaults" . | fromJsonArray -}}
{{- if and $found (include "openobserve.isLiveNewInstall" .) -}}
{{- fail (printf "these values are published defaults and must not be used on a new install: %s. Leave them empty to have the chart generate a value, or set your own." (join ", " $found)) -}}
{{- end -}}
{{- if not .Values.secretGenerator.enabled -}}
{{- $missing := list -}}
{{- if not .Values.externalSecret.enabled -}}
{{- if not .Values.auth.ZO_ROOT_USER_EMAIL }}{{ $missing = append $missing "auth.ZO_ROOT_USER_EMAIL" }}{{ end -}}
{{- if not .Values.auth.ZO_ROOT_USER_PASSWORD }}{{ $missing = append $missing "auth.ZO_ROOT_USER_PASSWORD" }}{{ end -}}
{{- end -}}
{{- if and .Values.postgres.enabled (not .Values.postgres.spec.password) }}{{ $missing = append $missing "postgres.spec.password" }}{{ end -}}
{{- if and .Values.postgres.enabled .Values.postgres.pgadmin.enabled (not .Values.postgres.pgadmin.PGADMIN_DEFAULT_PASSWORD) }}{{ $missing = append $missing "postgres.pgadmin.PGADMIN_DEFAULT_PASSWORD" }}{{ end -}}
{{- if and .Values.enterprise.enabled .Values.enterprise.dex.enabled -}}
{{- $client := index (.Values.enterprise.dex.config.staticClients | default (list dict)) 0 | default dict -}}
{{- if not (or $client.secret $client.secretEnv) }}{{ $missing = append $missing "enterprise.dex.config.staticClients[0].secret" }}{{ end -}}
{{- end -}}
{{- if $missing -}}
{{- fail (printf "secretGenerator.enabled is false, so set: %s" (join ", " $missing)) -}}
{{- end -}}
{{- end -}}
{{- end }}

{{/*
Dex config with the client secret read from O2_DEX_CLIENT_SECRET (secretEnv) when the user did not
set staticClients[0].secret, so the secret is never templated into the config.
*/}}
{{- define "openobserve.dexConfig" -}}
{{- $cfg := deepCopy .Values.enterprise.dex.config -}}
{{- $g := include "openobserve.generatedKeys" . | fromJson -}}
{{- if $g.dexClientSecret -}}
{{- $client := index $cfg.staticClients 0 -}}
{{- $_ := unset $client "secret" -}}
{{- $_ := set $client "secretEnv" "O2_DEX_CLIENT_SECRET" -}}
{{- end -}}
{{- toYaml $cfg -}}
{{- end }}

{{/*
The hook Job's script. It holds no secret value. Rules, per key:
- already in the generated Secret: keep it;
- new release (no chart ConfigMap, or one created with this Job): generate it;
- existing release (chart ConfigMap older than this Job, or secretGenerator.existingRelease): copy the value the release used so far (chart Secret, ConfigMap or Postgres user
  Secret), so nothing changes on upgrade. Without one, state keys (root user, gRPC token, salt) stay
  unset and the server keeps what it stored; keys for components enabled later are generated.
Derived keys (report user, tracing header, DSNs) are built from the effective values once.
*/}}
{{- define "openobserve.secretGeneratorScript" -}}
{{- $g := include "openobserve.generatedKeys" . | fromJson -}}
{{- $full := include "openobserve.fullname" . -}}
set -eu
NS={{ .Release.Namespace | quote }}
CHART_SECRET={{ $full | quote }}
CHART_CONFIGMAP={{ $full | quote }}
JOB={{ include "openobserve.secretGeneratorName" . | quote }}
LABELS='"app.kubernetes.io/name":{{ include "openobserve.name" . | quote }},"app.kubernetes.io/component":"generated-secret","openobserve.ai/release":{{ .Release.Name | quote }}'
{{- /* No app.kubernetes.io/instance label: Argo CD's label tracking would prune the Secret. */}}
ANNOTATIONS='"argocd.argoproj.io/compare-options":"IgnoreExtraneous","argocd.argoproj.io/sync-options":"Prune=false"'
umask 077

fail() { echo "secret-generator: $*" >&2; exit 1; }
exists() {
  if out=$(kubectl get "$1" "$2" -n "$NS" -o name 2>&1); then return 0; fi
  case "$out" in *NotFound*) return 1 ;; esac
  fail "cannot read $1/$2: $out"
}
field() { kubectl get "$1" "$2" -n "$NS" -o "jsonpath={.data.$3}"; }
rand() { tr -dc 'A-Za-z0-9' </dev/urandom | head -c "$1"; }
lower() { tr -dc 'a-z0-9' </dev/urandom | head -c "$1"; }
pick() { tr -dc "$1" </dev/urandom | head -c "$2"; }
# OpenObserve requires lower and upper case letters, a digit and a special character in passwords.
password() { printf '%s%s%s%s%s' "$(rand 24)" "$(pick a-z 2)" "$(pick A-Z 2)" "$(pick 0-9 2)" "$(pick '_@%+=.-' 2)"; }
b64() { printf '%s' "$1" | base64 | tr -d '\n'; }
unb64() { printf '%s' "$1" | base64 -d; }

# Existing release: the chart ConfigMap is older than this Job. With "helm template | kubectl apply"
# the ConfigMap is created in the same apply as the Job, so its existence alone proves nothing.
created() { date -u -d "$(kubectl get "$1" "$2" -n "$NS" -o jsonpath='{.metadata.creationTimestamp}' | sed 's/T/ /; s/Z$//')" +%s; }
OLD=no
case {{ .Values.secretGenerator.existingRelease | toString | quote }} in
  true) OLD=yes ;;
  false) OLD=no ;;
  *)
    if exists configmap "$CHART_CONFIGMAP"; then
      AGE=$(( $(created job "$JOB") - $(created configmap "$CHART_CONFIGMAP") ))
      if [ "$AGE" -gt 120 ]; then OLD=yes; fi
    fi ;;
esac
echo "existing release: $OLD"

# target NAME: start collecting keys for one Secret.
target() {
  TARGET=$1; ADD=""
  if exists secret "$TARGET"; then TARGET_EXISTS=yes; else TARGET_EXISTS=no; fi
}
current() {
  if [ "$TARGET_EXISTS" = yes ]; then field secret "$TARGET" "$1"; fi
}
add() { ADD="${ADD:+$ADD,}\"$1\":\"$2\""; }
# legacy SOURCE -> base64 value the existing release used, or nothing. SOURCE is kind/name/key or -.
legacy() {
  if [ "$1" = - ]; then return 0; fi
  kind=${1%%/*}; rest=${1#*/}; name=${rest%%/*}; key=${rest#*/}
  if ! exists "$kind" "$name"; then return 0; fi
  v=$(field "$kind" "$name" "$key")
  if [ -z "$v" ]; then return 0; fi
  if [ "$kind" = configmap ]; then b64 "$v"; else printf '%s' "$v"; fi
}
# state KEY KIND(email|password|token) LENGTH LEGACY_SOURCE GENERATE_ON_EXISTING_RELEASE -> RET (base64, may be empty)
state() {
  RET=$(current "$1")
  if [ -n "$RET" ]; then echo "kept $1"; return 0; fi
  if [ "$OLD" = yes ]; then
    RET=$(legacy "$4")
    if [ -n "$RET" ]; then add "$1" "$RET"; echo "copied $1 from the existing release"; return 0; fi
    if [ "$5" = no ]; then echo "left $1 unset: the existing release has no value for it"; return 0; fi
  fi
  case $2 in
    email) RET=$(b64 "root-$(lower 10)@openobserve.local") ;;
    password) RET=$(b64 "$(password)") ;;
    *) RET=$(b64 "$(rand "$3")") ;;
  esac
  add "$1" "$RET"; echo "generated $1"
}
# derived KEY BASE64_VALUE: add only when missing and the value is known.
derived() {
  if [ -z "$2" ] || [ -n "$(current "$1")" ]; then return 0; fi
  add "$1" "$2"; echo "derived $1"
}
# flush TYPE EXTRA_LABELS: create the Secret, or add the missing keys. Never changes a key.
flush() {
  if [ "$TARGET_EXISTS" = yes ]; then
    if [ -n "$ADD" ]; then
      printf '{"data":{%s}}' "$ADD" > /tmp/patch.json
      kubectl patch secret "$TARGET" -n "$NS" --type merge --patch-file /tmp/patch.json >/dev/null
      echo "added missing keys to $TARGET"
    else
      echo "$TARGET unchanged"
    fi
  else
    printf '{"apiVersion":"v1","kind":"Secret","type":"%s","metadata":{"name":"%s","namespace":"%s","labels":{%s%s},"annotations":{%s}},"data":{%s}}' \
      "$1" "$TARGET" "$NS" "$LABELS" "$2" "$ANNOTATIONS" "$ADD" > /tmp/secret.json
    kubectl create -f /tmp/secret.json >/dev/null
    echo "created $TARGET"
  fi
  rm -f /tmp/patch.json /tmp/secret.json
}

PG_PASSWORD=""
EMAIL=""
PASSWORD=""
{{- if $g.postgres }}
target {{ include "openobserve.postgresGeneratedSecretName" . | quote }}
derived username "$(b64 openobserve)"
state password token 32 "secret/{{ $full }}-openobservepguser/password" yes
PG_PASSWORD=$RET
flush kubernetes.io/basic-auth ',"cnpg.io/reload":"true"'
{{- end }}

target {{ include "openobserve.generatedSecretName" . | quote }}
{{- if $g.rootEmail }}
state ZO_ROOT_USER_EMAIL email 0 "secret/$CHART_SECRET/ZO_ROOT_USER_EMAIL" no
EMAIL=$RET
derived ZO_REPORT_USER_EMAIL "$EMAIL"
{{- end }}
{{- if $g.rootPassword }}
state ZO_ROOT_USER_PASSWORD password 32 "secret/$CHART_SECRET/ZO_ROOT_USER_PASSWORD" no
PASSWORD=$RET
derived ZO_REPORT_USER_PASSWORD "$PASSWORD"
{{- end }}
{{- if $g.tracing }}
if [ -n "$EMAIL" ] && [ -n "$PASSWORD" ]; then
  derived ZO_TRACING_HEADER_VALUE "$(b64 "Basic $(printf '%s:%s' "$(unb64 "$EMAIL")" "$(unb64 "$PASSWORD")" | base64 | tr -d '\n')")"
fi
{{- end }}
{{- if $g.grpcToken }}
state ZO_INTERNAL_GRPC_TOKEN token 48 "secret/$CHART_SECRET/ZO_INTERNAL_GRPC_TOKEN" no
{{- end }}
{{- if $g.salt }}
{{- /* An existing release keeps the salt the server already stored; changing it breaks presigned and ext-token logins. */}}
state ZO_EXT_AUTH_SALT token 32 - no
{{- end }}
{{- if $g.dexClientSecret }}
{{- $legacyDex := ternary "configmap/$CHART_CONFIGMAP/O2_DEX_CLIENT_SECRET" "secret/$CHART_SECRET/O2_DEX_CLIENT_SECRET" .Values.externalSecret.enabled }}
state O2_DEX_CLIENT_SECRET token 40 "{{ $legacyDex }}" yes
{{- end }}
{{- if $g.postgresDSN }}
if [ -n "$PG_PASSWORD" ]; then
  PG=$(unb64 "$PG_PASSWORD")
  derived ZO_META_POSTGRES_DSN "$(b64 "postgres://openobserve:$PG@{{ $full }}-postgres-rw.{{ .Release.Namespace }}.svc.{{ .Values.clusterDomain }}:5432/app?sslmode=disable")"
  derived ZO_META_POSTGRES_RO_DSN "$(b64 "postgres://openobserve:$PG@{{ $full }}-postgres-ro.{{ .Release.Namespace }}.svc.{{ .Values.clusterDomain }}:5432/app?sslmode=disable")"
fi
{{- end }}
{{- if $g.pgadmin }}
state PGADMIN_DEFAULT_PASSWORD token 24 - yes
{{- end }}
flush Opaque ''
{{- end }}
