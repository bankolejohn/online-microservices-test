{{/*
============================================================================
_helpers.tpl — reusable functions for the mono-chart
============================================================================
*/}}

{{/*
Full resource name: <serviceName>-<environment>
Example: cart-service-dev, cart-service-prod
This lets the SAME service run in multiple environments in one cluster.
*/}}
{{- define "mono-chart.fullname" -}}
{{- printf "%s-%s" .Values.serviceName .Values.environment | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels applied to every resource
*/}}
{{- define "mono-chart.labels" -}}
app: {{ include "mono-chart.fullname" . }}
app.kubernetes.io/name: {{ .Values.serviceName }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/part-of: online-shopping
environment: {{ .Values.environment }}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version }}
{{- end }}

{{/*
Selector labels — MUST be immutable (used in Deployment and Service selectors)
*/}}
{{- define "mono-chart.selectorLabels" -}}
app: {{ include "mono-chart.fullname" . }}
{{- end }}

{{/*
Full image reference: [registry/]name:tag
*/}}
{{- define "mono-chart.image" -}}
{{- if .Values.image.repository -}}
{{ .Values.image.repository }}/{{ .Values.image.name }}:{{ .Values.image.tag }}
{{- else -}}
{{ .Values.image.name }}:{{ .Values.image.tag }}
{{- end -}}
{{- end }}
