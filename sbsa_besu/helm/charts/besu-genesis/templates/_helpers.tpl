{{/*
Common labels for besu-genesis resources.
*/}}
{{- define "besu-genesis.labels" -}}
app.kubernetes.io/name: besu-genesis
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/part-of: besu
{{- end -}}
