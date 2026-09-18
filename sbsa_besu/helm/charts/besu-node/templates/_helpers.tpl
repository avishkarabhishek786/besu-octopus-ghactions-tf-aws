{{/*
Fullname: prefer fullnameOverride (Terraform sets it = release name) so the
StatefulSet and headless Service have a deterministic name that matches the
enode DNS hosts other nodes are configured with.
*/}}
{{- define "besu-node.fullname" -}}
{{- if .Values.fullnameOverride -}}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- printf "%s-%s" .Release.Name .Chart.Name | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}

{{- define "besu-node.labels" -}}
app.kubernetes.io/name: besu-node
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/part-of: besu
besu.role: {{ .Values.role }}
{{- end -}}

{{- define "besu-node.selectorLabels" -}}
app.kubernetes.io/name: besu-node
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}
