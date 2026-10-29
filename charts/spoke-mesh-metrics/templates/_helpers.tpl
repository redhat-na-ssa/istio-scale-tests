{{- define "spoke-mesh-metrics.labels" -}}
app.kubernetes.io/name: spoke-mesh-metrics
app.kubernetes.io/instance: {{ .Release.Name | quote }}
{{- with .Values.clusterName }}
spoke-mesh-metrics/cluster-name: {{ . | quote }}
{{- end }}
{{- end }}

{{/*
The namespace this release covers, once it is a namespace name (a DNS-1123 label). Every
template calls it, so an empty or invalid one fails the whole render.
*/}}
{{- define "spoke-mesh-metrics.namespace" -}}
{{- $ns := toString (.Values.namespace | default "") -}}
{{- if not $ns -}}
{{- fail "namespace is empty: set the one namespace this release covers (the ApplicationSet sets it from terraform/platform acm_observability.istio_metrics_namespaces)" -}}
{{- end -}}
{{- if or (gt (len $ns) 63) (not (regexMatch "^[a-z0-9]([-a-z0-9]*[a-z0-9])?$" $ns)) -}}
{{- fail (printf "namespace %q is not a namespace name (a DNS-1123 label: at most 63 lowercase letters, digits and '-', starting and ending with a letter or digit)" $ns) -}}
{{- end -}}
{{- $ns -}}
{{- end }}

{{/*
"true" when this release covers istiod's namespace (it then also scrapes istiod and owns user
workload monitoring), else empty.
*/}}
{{- define "spoke-mesh-metrics.isIstioNamespace" -}}
{{- if eq (include "spoke-mesh-metrics.namespace" .) (toString .Values.istioNamespace) }}true{{ end -}}
{{- end }}

{{/*
A metric name list (dict "list" <names> "key" <values key>) joined by "|" for a keep regex,
once every entry is an exact metric name: the ACM allowlist matches names, not patterns.
*/}}
{{- define "spoke-mesh-metrics.keepRegex" -}}
{{- $names := list -}}
{{- range .list -}}
{{- $n := toString . -}}
{{- if not (regexMatch "^[a-zA-Z_:][a-zA-Z0-9_:]*$" $n) -}}
{{- fail (printf "%s: %q is not an exact metric name (the ACM allowlist matches names, not patterns: list each one)" $.key $n) -}}
{{- end -}}
{{- $names = append $names $n -}}
{{- end -}}
{{- if not $names -}}
{{- fail (printf "%s is empty: list the metric names to keep" .key) -}}
{{- end -}}
{{- join "|" $names -}}
{{- end }}

{{/*
The allowlisted names in this release's namespace, one per line, sorted and unique: the
proxies' in every namespace, plus istiod's in istiod's namespace. The same lists as the keep
regexes, so a kept series is always allowlisted and an allowlisted one always kept.
*/}}
{{- define "spoke-mesh-metrics.allowlistNames" -}}
{{- $names := .Values.proxyMetrics -}}
{{- if include "spoke-mesh-metrics.isIstioNamespace" . -}}
{{- $names = concat $names .Values.istiodMetrics -}}
{{- end -}}
{{- range $names | uniq | sortAlpha }}
{{ toString . }}
{{- end -}}
{{- end }}
