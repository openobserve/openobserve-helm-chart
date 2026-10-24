{{/*
Pod template shared by the agent DaemonSet and the gateway StatefulSet.
*/}}
{{- define "otel-fleet-collector.podTemplate" -}}
{{- $roleName := include "otel-fleet-collector.role" . }}
{{- $role := index .Values $roleName }}
{{- $agent := eq $roleName "agent" }}
{{- $hostLogs := include "otel-fleet-collector.hostLogs" . -}}
metadata:
  annotations:
    checksum/config: {{ include (print $.Template.BasePath "/configmap.yaml") . | sha256sum }}
    {{- if not .Values.opamp.existingSecret }}
    checksum/secret: {{ include (print $.Template.BasePath "/secret.yaml") . | sha256sum }}
    {{- end }}
    {{- with .Values.podAnnotations }}
    {{- toYaml . | nindent 4 }}
    {{- end }}
  labels:
    {{- include "otel-fleet-collector.selectorLabels" . | nindent 4 }}
    {{- with .Values.podLabels }}
    {{- toYaml . | nindent 4 }}
    {{- end }}
spec:
  {{- with .Values.imagePullSecrets }}
  imagePullSecrets:
    {{- toYaml . | nindent 4 }}
  {{- end }}
  serviceAccountName: {{ include "otel-fleet-collector.serviceAccountName" . }}
  hostNetwork: false
  {{- with .Values.priorityClassName }}
  priorityClassName: {{ . }}
  {{- end }}
  terminationGracePeriodSeconds: {{ .Values.terminationGracePeriodSeconds }}
  securityContext:
    {{- include "otel-fleet-collector.podSecurityContext" . | nindent 4 }}
  initContainers:
    # Runs as root: the distroless supervisor image has no shell to render the token
    # into the config, and the state directory must be owned by whichever uid the
    # supervisor runs as (a node installed with the other hostLogs setting, an older
    # chart, or a freshly provisioned volume may have it owned by another one).
    - name: init
      image: "{{ .Values.initContainer.image.repository }}:{{ .Values.initContainer.image.tag }}"
      imagePullPolicy: {{ .Values.initContainer.image.pullPolicy }}
      securityContext:
        runAsUser: 0
        runAsGroup: 0
        runAsNonRoot: false
        allowPrivilegeEscalation: false
        readOnlyRootFilesystem: true
        capabilities:
          drop:
            - ALL
          add:
            - CHOWN
            - FOWNER
            - DAC_OVERRIDE
      command:
        - /bin/sh
        - -ec
        - |
          chown -R {{ ternary "0:0" "65532:65532" (eq $hostLogs "true") }} /var/lib/opampsupervisor
          AUTH=$(printf 'fleet:%s' "$O2_FLEET_TOKEN" | base64 | tr -d '\n')
          sed "s|__O2_FLEET_AUTH__|$AUTH|g" /etc/opampsupervisor-template/supervisor.yaml > /etc/opampsupervisor/supervisor.yaml
      env:
        - name: O2_FLEET_TOKEN
          valueFrom:
            secretKeyRef:
              name: {{ include "otel-fleet-collector.secretName" . }}
              key: {{ include "otel-fleet-collector.secretKey" . }}
      {{- with .Values.initContainer.resources }}
      resources:
        {{- toYaml . | nindent 8 }}
      {{- end }}
      volumeMounts:
        - name: state
          mountPath: /var/lib/opampsupervisor
        - name: config-template
          mountPath: /etc/opampsupervisor-template
          readOnly: true
        - name: config
          mountPath: /etc/opampsupervisor
  containers:
    - name: supervisor
      image: "{{ .Values.image.repository }}:{{ .Values.image.tag | default .Chart.AppVersion }}"
      imagePullPolicy: {{ .Values.image.pullPolicy }}
      securityContext:
        {{- include "otel-fleet-collector.securityContext" . | nindent 8 }}
      env:
        - name: K8S_NODE_NAME
          valueFrom:
            fieldRef:
              fieldPath: spec.nodeName
        - name: K8S_POD_NAME
          valueFrom:
            fieldRef:
              fieldPath: metadata.name
        - name: K8S_NAMESPACE
          valueFrom:
            fieldRef:
              fieldPath: metadata.namespace
        {{- with .Values.extraEnv }}
        {{- toYaml . | nindent 8 }}
        {{- end }}
      {{- if and (not $agent) .Values.gateway.service.enabled }}
      ports:
        {{- range .Values.gateway.service.ports }}
        - name: {{ .name }}
          containerPort: {{ .port }}
          protocol: TCP
        {{- end }}
      {{- end }}
      {{- with $role.resources }}
      resources:
        {{- toYaml . | nindent 8 }}
      {{- end }}
      volumeMounts:
        - name: config
          mountPath: /etc/opampsupervisor
          readOnly: true
        - name: state
          mountPath: /var/lib/opampsupervisor
        {{- if $hostLogs }}
        {{- range $i, $p := .Values.agent.hostLogs.paths }}
        - name: hostlog-{{ $i }}
          mountPath: {{ $p }}
          readOnly: true
        {{- end }}
        {{- end }}
        {{- with .Values.extraVolumeMounts }}
        {{- toYaml . | nindent 8 }}
        {{- end }}
  volumes:
    - name: config-template
      configMap:
        name: {{ include "otel-fleet-collector.fullname" . }}
    - name: config
      emptyDir: {}
    {{- if $agent }}
    - name: state
      hostPath:
        path: {{ .Values.agent.storage.hostPath }}
        type: DirectoryOrCreate
    {{- else if not .Values.gateway.persistence.enabled }}
    - name: state
      emptyDir: {}
    {{- end }}
    {{- if $hostLogs }}
    {{- range $i, $p := .Values.agent.hostLogs.paths }}
    - name: hostlog-{{ $i }}
      hostPath:
        path: {{ $p }}
        type: DirectoryOrCreate
    {{- end }}
    {{- end }}
    {{- with .Values.extraVolumes }}
    {{- toYaml . | nindent 4 }}
    {{- end }}
  {{- with $role.nodeSelector }}
  nodeSelector:
    {{- toYaml . | nindent 4 }}
  {{- end }}
  {{- with $role.affinity }}
  affinity:
    {{- toYaml . | nindent 4 }}
  {{- end }}
  {{- with $role.tolerations }}
  tolerations:
    {{- toYaml . | nindent 4 }}
  {{- end }}
{{- end }}
