{{/* vim: set filetype=mustache: */}}
{{/*
Name of the chart
*/}}
{{- define "volsync.name" -}}
{{- default .Release.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/*
Name of the bootstrap destination
*/}}
{{- define "volsync.bootstrap" -}}
{{- printf "%s-bootstrap" (include "volsync.name" .) -}}
{{- end -}}

{{/*
Name of the bootstrap destination
*/}}
{{- define "volsync.restic.secret" -}}
{{- printf "%s-volsync" (include "volsync.name" .) -}}
{{- end -}}
