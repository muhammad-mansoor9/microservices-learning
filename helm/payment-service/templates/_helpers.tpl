{{/*
Chart name.
*/}}
{{- define "payment-service.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/*
Fully qualified app name.
*/}}
{{- define "payment-service.fullname" -}}
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
{{- define "payment-service.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/*
Common labels.
*/}}
{{- define "payment-service.labels" -}}
helm.sh/chart: {{ include "payment-service.chart" . }}
{{ include "payment-service.selectorLabels" . }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end -}}

{{/*
Selector labels.
*/}}
{{- define "payment-service.selectorLabels" -}}
app.kubernetes.io/name: {{ include "payment-service.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}

{{/*
Service account name.
*/}}
{{- define "payment-service.serviceAccountName" -}}
{{- include "payment-service.fullname" . -}}
{{- end -}}

{{/*
OTel agent download URL.
*/}}
{{- define "payment-service.otelAgentUrl" -}}
{{- if .Values.otel.agentUrl -}}
{{- .Values.otel.agentUrl -}}
{{- else -}}
{{- printf "https://github.com/open-telemetry/opentelemetry-java-instrumentation/releases/download/v%s/opentelemetry-javaagent.jar" .Values.otel.agentVersion -}}
{{- end -}}
{{- end -}}
