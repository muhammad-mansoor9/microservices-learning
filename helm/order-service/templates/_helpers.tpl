{{/*
Chart name.
*/}}
{{- define "order-service.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/*
Fully qualified app name.
*/}}
{{- define "order-service.fullname" -}}
{{- if .Values.fullnameOverride -}}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- $name := default .Chart.Name .Values.nameOverride -}}
{{- if contains $name .Release.Name -}}
{{- .Release.Name | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{/*
Chart label.
*/}}
{{- define "order-service.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/*
Common labels.
*/}}
{{- define "order-service.labels" -}}
helm.sh/chart: {{ include "order-service.chart" . }}
{{ include "order-service.selectorLabels" . }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end -}}

{{/*
Selector labels.
*/}}
{{- define "order-service.selectorLabels" -}}
app.kubernetes.io/name: {{ include "order-service.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}

{{/*
Service account name.
*/}}
{{- define "order-service.serviceAccountName" -}}
{{- include "order-service.fullname" . -}}
{{- end -}}

{{/*
OTel agent download URL. If otel.agentUrl is set, use it verbatim; otherwise
derive from otel.agentVersion.
*/}}
{{- define "order-service.otelAgentUrl" -}}
{{- if .Values.otel.agentUrl -}}
{{- .Values.otel.agentUrl -}}
{{- else -}}
{{- printf "https://github.com/open-telemetry/opentelemetry-java-instrumentation/releases/download/v%s/opentelemetry-javaagent.jar" .Values.otel.agentVersion -}}
{{- end -}}
{{- end -}}
