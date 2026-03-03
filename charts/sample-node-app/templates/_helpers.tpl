{{- define "sample-node-app.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "sample-node-app.fullname" -}}
{{- include "sample-node-app.name" . -}}
{{- end -}}
