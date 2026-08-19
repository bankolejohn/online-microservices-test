{{/*
============================================================================
_helpers.tpl — Reusable template functions
============================================================================
These are Go template functions that other templates call.
Convention: names starting with "online-shopping." to avoid conflicts.

Think of these as utility functions — they generate consistent labels,
names, and selectors across all resources.
============================================================================
*/}}

{{/*
Chart name (truncated to 63 chars — Kubernetes name limit)
*/}}
{{- define "online-shopping.name" -}}
{{- .Chart.Name | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Fully qualified app name (release + chart, truncated)
*/}}
{{- define "online-shopping.fullname" -}}
{{- if contains .Chart.Name .Release.Name }}
{{- .Release.Name | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- printf "%s-%s" .Release.Name .Chart.Name | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}

{{/*
Common labels applied to every resource (for filtering and selection)
*/}}
{{- define "online-shopping.labels" -}}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/part-of: online-shopping
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version }}
{{- end }}

{{/*
Service-specific labels (used on individual service resources)
*/}}
{{- define "online-shopping.serviceLabels" -}}
app: {{ .name }}
app.kubernetes.io/name: {{ .name }}
app.kubernetes.io/component: {{ .component | default "backend" }}
{{- end }}

{{/*
Selector labels (used in Deployment.spec.selector and Service.spec.selector)
These MUST be immutable — never add labels here that might change
*/}}
{{- define "online-shopping.selectorLabels" -}}
app: {{ .name }}
{{- end }}

{{/*
Image reference — combines registry + image name + tag
Examples:
  Dev:  cart-service:latest (no registry)
  Prod: ghcr.io/bankolejohn/online-shopping/cart-service:sha-a1b2c3d
*/}}
{{- define "online-shopping.image" -}}
{{- $registry := .global.imageRegistry -}}
{{- $tag := .tag | default .global.imageTag -}}
{{- if $registry -}}
{{ $registry }}/{{ .image }}:{{ $tag }}
{{- else -}}
{{ .image }}:{{ $tag }}
{{- end -}}
{{- end }}
