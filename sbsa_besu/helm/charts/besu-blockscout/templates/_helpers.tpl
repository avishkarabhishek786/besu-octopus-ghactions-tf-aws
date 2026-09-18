{{- define "blockscout.name" -}}
{{- default "blockscout" .Values.nameOverride -}}
{{- end -}}

{{- /* Common labels — deliberately WITHOUT app.kubernetes.io/name, so each
       resource sets its own name label (the postgres StatefulSet uses a
       "-postgres" name that must match its immutable selector). */ -}}
{{- define "blockscout.labels" -}}
app.kubernetes.io/part-of: besu-blockscout
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end -}}

{{- define "blockscout.frontendName" -}}
{{ include "blockscout.name" . }}-frontend
{{- end -}}

{{- define "blockscout.proxyName" -}}
{{ include "blockscout.name" . }}-proxy
{{- end -}}

{{- /* In-namespace service DNS used by the nginx proxy upstreams. */ -}}
{{- define "blockscout.backendHost" -}}
{{ include "blockscout.name" . }}.{{ .Values.namespace }}.svc.cluster.local
{{- end -}}
{{- define "blockscout.frontendHost" -}}
{{ include "blockscout.frontendName" . }}.{{ .Values.namespace }}.svc.cluster.local
{{- end -}}

{{- define "blockscout.statsName" -}}
{{ include "blockscout.name" . }}-stats
{{- end -}}
{{- define "blockscout.visualizerName" -}}
{{ include "blockscout.name" . }}-visualizer
{{- end -}}

{{- define "blockscout.pgHost" -}}
{{ include "blockscout.name" . }}-postgres.{{ .Values.namespace }}.svc.cluster.local
{{- end -}}

{{- define "blockscout.databaseUrl" -}}
postgresql://{{ .Values.postgres.username }}:$(DB_PASSWORD)@{{ include "blockscout.pgHost" . }}:{{ .Values.postgres.port }}/{{ .Values.postgres.database }}
{{- end -}}
