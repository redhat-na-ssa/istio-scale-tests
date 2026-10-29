{{/*
Labels of every object of this chart.
*/}}
{{- define "kiali.labels" -}}
app.kubernetes.io/name: {{ .Chart.Name | quote }}
app.kubernetes.io/instance: {{ .Release.Name | trunc 63 | trimSuffix "-" | quote }}
{{- end }}

{{/*
The mode, hub or remote; any other value fails the render. remote also needs clusterName and
hubRedirectBase, or the operator would refuse the CR (no redirect URI) and the hub's login
callback would not match.
*/}}
{{- define "kiali.mode" -}}
{{- $m := toString .Values.mode -}}
{{- if not (has $m (list "hub" "remote")) -}}
{{- fail (printf "mode must be hub or remote, not %q" $m) -}}
{{- end -}}
{{- if eq $m "remote" -}}
{{- if not .Values.clusterName -}}
{{- fail "mode remote needs clusterName, the member's cluster name, set by the ApplicationSet (values-kiali.yaml)" -}}
{{- end -}}
{{- if not .Values.hubRedirectBase -}}
{{- fail "mode remote needs hubRedirectBase (https://kiali-istio-system.<hub apps domain>/api/auth/callback), set by terraform/platform (kiali_multicluster)" -}}
{{- end -}}
{{- end -}}
{{- $m -}}
{{- end }}

{{/*
"true" or "false" from viewOnly, whether a bool or a string.
*/}}
{{- define "kiali.viewOnly" -}}
{{- ternary "true" "false" (eq (toString .Values.viewOnly) "true") -}}
{{- end }}
