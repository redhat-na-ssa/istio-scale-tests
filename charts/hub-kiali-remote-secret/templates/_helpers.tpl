{{/*
Labels of every object of this chart.
*/}}
{{- define "hub-kiali-remote-secret.labels" -}}
app.kubernetes.io/name: {{ .Chart.Name | quote }}
app.kubernetes.io/instance: {{ .Release.Name | trunc 63 | trimSuffix "-" | quote }}
{{- end }}

{{/*
The member's kubeconfig Secret on the hub (charts/hub-kubeconfig-from-argosecret).
*/}}
{{- define "hub-kiali-remote-secret.kubeconfigSecret" -}}
{{- .Values.kubeconfigSourceSecretName | default (printf "kubeconfig-%s" .Values.clusterName) -}}
{{- end }}

{{/*
The annotations block with the sync wave named by .wave, or nothing when waves are off.
Call with (dict "root" $ "wave" "<name>").
*/}}
{{- define "hub-kiali-remote-secret.waveAnnotations" -}}
{{- if .root.Values.argoSyncWaves.enabled -}}
annotations:
  argocd.argoproj.io/sync-wave: {{ index .root.Values.argoSyncWaves .wave | quote }}
{{- end -}}
{{- end }}
