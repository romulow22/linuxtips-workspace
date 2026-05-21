{{/*
tipsbank.labels — labels comuns aplicados em todos os recursos.
*/}}
{{- define "tipsbank.labels" -}}
team: {{ .Values.global.team }}
env: {{ .Values.global.env }}
helm.sh/chart: {{ .Chart.Name }}-{{ .Chart.Version }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
tipsbank.selectorLabels — labels usados em selector.matchLabels (imutáveis após criação).
Recebe dict com "app" e "root" (o contexto raiz . com .Values).
*/}}
{{- define "tipsbank.selectorLabels" -}}
app: {{ .app }}
{{- end }}

{{/*
tipsbank.podLabels — labels do pod template (selector + extras).
*/}}
{{- define "tipsbank.podLabels" -}}
app: {{ .app }}
team: {{ .root.Values.global.team }}
env: {{ .root.Values.global.env }}
{{- end }}

{{/*
tipsbank.imagePullPolicy
*/}}
{{- define "tipsbank.imagePullPolicy" -}}
{{ .Values.global.imagePullPolicy | default "IfNotPresent" }}
{{- end }}
