{{/* vim: set filetype=mustache: */}}
{{/*
Expand the name of the chart.
*/}}
{{- define "minecraft.bedrock.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/*
Create a default fully qualified app name.
We truncate at 63 chars because some Kubernetes name fields are limited to this (by the DNS naming spec).
If release name contains chart name it will be used as a full name.
*/}}
{{- define "minecraft.bedrock.fullname" -}}
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
Create argocd server name and version as used by the chart label.
*/}}
{{- define "minecraft.bedrock.map.fullname" -}}
{{- printf "%s-%s" (include "minecraft.bedrock.fullname" .) "map" | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/*
Common labels
*/}}
{{- define "minecraft.bedrock.labels" -}}
helm.sh/chart: {{ include "minecraft.bedrock.chart" .context }}
{{ include "minecraft.bedrock.selectorLabels" (dict "context" .context "component" .component "name" .name) }}
app.kubernetes.io/managed-by: {{ .context.Release.Service }}
app.kubernetes.io/part-of: minecraft.bedrock
{{- end }}

{{/*
Selector labels
*/}}
{{- define "minecraft.bedrock.selectorLabels" -}}
{{- if .name -}}
app.kubernetes.io/name: {{ include "minecraft.bedrock.name" .context }}-{{ .name }}
{{ end -}}
app.kubernetes.io/instance: {{ .context.Release.Name }}
{{- if .component }}
app.kubernetes.io/component: {{ .component }}
{{- end }}
{{- end }}

{{/*
Create chart name and version as used by the chart label.
*/}}
{{- define "minecraft.bedrock.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/*
Checksum annotations
*/}}
{{- define "minecraft.bedrock.checksumAnnotations" -}}
checksum/config: {{ include (print $.Template.BasePath "/configmap.yaml") . | sha256sum }}
{{- end }}
