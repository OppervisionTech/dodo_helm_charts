{{/*
=======================================================================
AegisOps Library Chart — Shared Helpers
=======================================================================
All application charts include this library as a dependency.
Helpers follow Kubernetes recommended labels (app.kubernetes.io/*).
=======================================================================
*/}}

{{/*
----------------------------------------------------------------------
aegis.name — Chart name, truncated to 63 chars.
----------------------------------------------------------------------
*/}}
{{- define "aegis.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
----------------------------------------------------------------------
aegis.fullname — Full resource name: <release>-<chart>, truncated to 63 chars.
If release name contains chart name, avoid duplication.
----------------------------------------------------------------------
*/}}
{{- define "aegis.fullname" -}}
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
----------------------------------------------------------------------
aegis.chart — Chart name and version for chart label.
----------------------------------------------------------------------
*/}}
{{- define "aegis.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
----------------------------------------------------------------------
aegis.labels — Standard Kubernetes recommended labels.
  app.kubernetes.io/name
  app.kubernetes.io/instance
  app.kubernetes.io/version
  app.kubernetes.io/component
  app.kubernetes.io/managed-by
  helm.sh/chart
----------------------------------------------------------------------
*/}}
{{- define "aegis.labels" -}}
helm.sh/chart: {{ include "aegis.chart" . }}
app.kubernetes.io/name: {{ include "aegis.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
{{- if .Values.component }}
app.kubernetes.io/component: {{ .Values.component }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/part-of: aegisops
{{- end }}

{{/*
----------------------------------------------------------------------
aegis.selectorLabels — Subset of labels used in selectors.
Must be immutable after creation (no version).
----------------------------------------------------------------------
*/}}
{{- define "aegis.selectorLabels" -}}
app.kubernetes.io/name: {{ include "aegis.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
----------------------------------------------------------------------
aegis.annotations — Standard annotations for all resources.
Includes deploy timestamp, version, and git-sha if available.
----------------------------------------------------------------------
*/}}
{{- define "aegis.annotations" -}}
aegisops.io/deploy-timestamp: {{ now | date "2006-01-02T15:04:05Z" | quote }}
{{- if .Chart.AppVersion }}
aegisops.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
{{- if .Values.gitSha }}
aegisops.io/git-sha: {{ .Values.gitSha | quote }}
{{- end }}
{{- with .Values.extraAnnotations }}
{{ toYaml . }}
{{- end }}
{{- end }}

{{/*
----------------------------------------------------------------------
aegis.resourceLimits — Resource requests and limits.
Parameters (via .Values.resources):
  requests.cpu     (default: 100m)
  requests.memory  (default: 128Mi)
  limits.cpu       (default: 500m)
  limits.memory    (default: 512Mi)
----------------------------------------------------------------------
*/}}
{{- define "aegis.resourceLimits" -}}
resources:
  requests:
    cpu: {{ .Values.resources.requests.cpu | default "100m" }}
    memory: {{ .Values.resources.requests.memory | default "128Mi" }}
  limits:
    cpu: {{ .Values.resources.limits.cpu | default "500m" }}
    memory: {{ .Values.resources.limits.memory | default "512Mi" }}
{{- end }}

{{/*
----------------------------------------------------------------------
aegis.healthCheck — Liveness and readiness probes.
Parameters (via .Values.health):
  liveness.path             (default: /healthz)
  liveness.port             (default: http)
  liveness.initialDelay     (default: 15)
  liveness.period           (default: 20)
  liveness.timeout          (default: 5)
  liveness.failureThreshold (default: 3)
  readiness.path            (default: /readyz)
  readiness.port            (default: http)
  readiness.initialDelay    (default: 5)
  readiness.period          (default: 10)
  readiness.timeout         (default: 3)
  readiness.failureThreshold(default: 3)
  type                      (default: http — options: http, grpc, tcp)
----------------------------------------------------------------------
*/}}
{{- define "aegis.healthCheck" -}}
{{- $type := .Values.health.type | default "http" }}
{{- if eq $type "http" }}
livenessProbe:
  httpGet:
    path: {{ .Values.health.liveness.path | default "/healthz" }}
    port: {{ .Values.health.liveness.port | default "http" }}
  initialDelaySeconds: {{ .Values.health.liveness.initialDelay | default 15 }}
  periodSeconds: {{ .Values.health.liveness.period | default 20 }}
  timeoutSeconds: {{ .Values.health.liveness.timeout | default 5 }}
  failureThreshold: {{ .Values.health.liveness.failureThreshold | default 3 }}
readinessProbe:
  httpGet:
    path: {{ .Values.health.readiness.path | default "/readyz" }}
    port: {{ .Values.health.readiness.port | default "http" }}
  initialDelaySeconds: {{ .Values.health.readiness.initialDelay | default 5 }}
  periodSeconds: {{ .Values.health.readiness.period | default 10 }}
  timeoutSeconds: {{ .Values.health.readiness.timeout | default 3 }}
  failureThreshold: {{ .Values.health.readiness.failureThreshold | default 3 }}
{{- else if eq $type "grpc" }}
livenessProbe:
  grpc:
    port: {{ .Values.health.liveness.port | default 50051 }}
  initialDelaySeconds: {{ .Values.health.liveness.initialDelay | default 15 }}
  periodSeconds: {{ .Values.health.liveness.period | default 20 }}
  timeoutSeconds: {{ .Values.health.liveness.timeout | default 5 }}
  failureThreshold: {{ .Values.health.liveness.failureThreshold | default 3 }}
readinessProbe:
  grpc:
    port: {{ .Values.health.readiness.port | default 50051 }}
  initialDelaySeconds: {{ .Values.health.readiness.initialDelay | default 5 }}
  periodSeconds: {{ .Values.health.readiness.period | default 10 }}
  timeoutSeconds: {{ .Values.health.readiness.timeout | default 3 }}
  failureThreshold: {{ .Values.health.readiness.failureThreshold | default 3 }}
{{- else if eq $type "tcp" }}
livenessProbe:
  tcpSocket:
    port: {{ .Values.health.liveness.port | default "tcp" }}
  initialDelaySeconds: {{ .Values.health.liveness.initialDelay | default 15 }}
  periodSeconds: {{ .Values.health.liveness.period | default 20 }}
  timeoutSeconds: {{ .Values.health.liveness.timeout | default 5 }}
  failureThreshold: {{ .Values.health.liveness.failureThreshold | default 3 }}
readinessProbe:
  tcpSocket:
    port: {{ .Values.health.readiness.port | default "tcp" }}
  initialDelaySeconds: {{ .Values.health.readiness.initialDelay | default 5 }}
  periodSeconds: {{ .Values.health.readiness.period | default 10 }}
  timeoutSeconds: {{ .Values.health.readiness.timeout | default 3 }}
  failureThreshold: {{ .Values.health.readiness.failureThreshold | default 3 }}
{{- end }}
{{- end }}

{{/*
----------------------------------------------------------------------
aegis.serviceAccount — ServiceAccount with minimum privileges.
Creates a ServiceAccount with automountServiceAccountToken: false.
Parameters (via .Values.serviceAccount):
  create (default: true)
  name   (default: aegis.fullname)
  annotations (optional)
----------------------------------------------------------------------
*/}}
{{- define "aegis.serviceAccount" -}}
{{- if .Values.serviceAccount.create | default true }}
apiVersion: v1
kind: ServiceAccount
metadata:
  name: {{ .Values.serviceAccount.name | default (include "aegis.fullname" .) }}
  labels:
    {{- include "aegis.labels" . | nindent 4 }}
  {{- with .Values.serviceAccount.annotations }}
  annotations:
    {{- toYaml . | nindent 4 }}
  {{- end }}
automountServiceAccountToken: false
{{- end }}
{{- end }}

{{/*
----------------------------------------------------------------------
aegis.serviceAccountName — Returns the ServiceAccount name to use.
----------------------------------------------------------------------
*/}}
{{- define "aegis.serviceAccountName" -}}
{{- if .Values.serviceAccount.create | default true }}
{{- .Values.serviceAccount.name | default (include "aegis.fullname" .) }}
{{- else }}
{{- .Values.serviceAccount.name | default "default" }}
{{- end }}
{{- end }}

{{/*
----------------------------------------------------------------------
aegis.podSecurityContext — Pod-level security context.
Follows CIS Kubernetes Benchmark:
  runAsNonRoot, fsGroup, seccompProfile.
----------------------------------------------------------------------
*/}}
{{- define "aegis.podSecurityContext" -}}
securityContext:
  runAsNonRoot: true
  runAsUser: {{ .Values.podSecurityContext.runAsUser | default 65534 }}
  runAsGroup: {{ .Values.podSecurityContext.runAsGroup | default 65534 }}
  fsGroup: {{ .Values.podSecurityContext.fsGroup | default 65534 }}
  seccompProfile:
    type: RuntimeDefault
{{- end }}

{{/*
----------------------------------------------------------------------
aegis.containerSecurityContext — Container-level security context.
Follows CIS Kubernetes Benchmark:
  readOnlyRootFilesystem, drop ALL capabilities, no privilege escalation.
----------------------------------------------------------------------
*/}}
{{- define "aegis.containerSecurityContext" -}}
securityContext:
  readOnlyRootFilesystem: {{ .Values.containerSecurityContext.readOnlyRootFilesystem | default true }}
  allowPrivilegeEscalation: false
  runAsNonRoot: true
  capabilities:
    drop:
      - ALL
    {{- with .Values.containerSecurityContext.addCapabilities }}
    add:
      {{- toYaml . | nindent 6 }}
    {{- end }}
{{- end }}

{{/*
----------------------------------------------------------------------
aegis.networkPolicy — NetworkPolicy template.
Default: deny-all ingress/egress, then allow specific rules.
Parameters (via .Values.networkPolicy):
  enabled        (default: true)
  ingress        (list of rules)
  egress         (list of rules)
  allowDNS       (default: true — always allow DNS egress)
----------------------------------------------------------------------
*/}}
{{- define "aegis.networkPolicy" -}}
{{- if .Values.networkPolicy.enabled | default true }}
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: {{ include "aegis.fullname" . }}
  labels:
    {{- include "aegis.labels" . | nindent 4 }}
spec:
  podSelector:
    matchLabels:
      {{- include "aegis.selectorLabels" . | nindent 6 }}
  policyTypes:
    - Ingress
    - Egress
  {{- if .Values.networkPolicy.ingress }}
  ingress:
    {{- toYaml .Values.networkPolicy.ingress | nindent 4 }}
  {{- end }}
  egress:
    {{- if .Values.networkPolicy.allowDNS | default true }}
    # Always allow DNS
    - to: []
      ports:
        - protocol: UDP
          port: 53
        - protocol: TCP
          port: 53
    {{- end }}
    {{- with .Values.networkPolicy.egress }}
    {{- toYaml . | nindent 4 }}
    {{- end }}
{{- end }}
{{- end }}

{{/*
----------------------------------------------------------------------
aegis.secretRef — Reference to an ExternalSecret or SealedSecret.
Never stores secrets in plain text.
Parameters:
  name — name of the Kubernetes Secret to reference
----------------------------------------------------------------------
*/}}
{{- define "aegis.secretRef" -}}
envFrom:
  - secretRef:
      name: {{ . }}
{{- end }}

{{/*
----------------------------------------------------------------------
aegis.prometheusAnnotations — Prometheus scraping annotations.
Parameters (via .Values.metrics):
  enabled  (default: true)
  port     (default: 9090)
  path     (default: /metrics)
----------------------------------------------------------------------
*/}}
{{- define "aegis.prometheusAnnotations" -}}
{{- if .Values.metrics.enabled | default true }}
prometheus.io/scrape: "true"
prometheus.io/port: {{ .Values.metrics.port | default "9090" | quote }}
prometheus.io/path: {{ .Values.metrics.path | default "/metrics" | quote }}
{{- end }}
{{- end }}

{{/*
----------------------------------------------------------------------
aegis.image — Container image reference.
Parameters (via .Values.image):
  repository
  tag (default: Chart.AppVersion)
  pullPolicy (default: IfNotPresent)
----------------------------------------------------------------------
*/}}
{{- define "aegis.image" -}}
image: "{{ .Values.image.repository }}:{{ .Values.image.tag | default .Chart.AppVersion }}"
imagePullPolicy: {{ .Values.image.pullPolicy | default "IfNotPresent" }}
{{- end }}
