{{/*
Labels for ApplicationSet and RBAC (distinct per preset via identity.component / applicationSet.name).
*/}}
{{- define "gitops-hub-ocm-placement-appset.labels" -}}
app.kubernetes.io/name: {{ .Chart.Name | quote }}
app.kubernetes.io/instance: {{ .Values.applicationSet.name | default .Release.Name | quote }}
app.kubernetes.io/component: {{ .Values.identity.component | default "ocm-placement-appset" | quote }}
{{- end }}

{{/*
The member generator: clusters (Argo CD cluster Secrets) or clusterDecisionResource (ACM).
*/}}
{{- define "gitops-hub-ocm-placement-appset.generator" -}}
{{- $g := .Values.generator | default "clusters" -}}
{{- if not (has $g (list "clusters" "clusterDecisionResource")) -}}
{{- fail (printf "generator must be clusters (Argo CD cluster Secrets) or clusterDecisionResource (ACM PlacementDecisions), not %q" $g) -}}
{{- end -}}
{{- $g -}}
{{- end }}

{{/*
The member generator at indent 0, which applicationset.yaml indents (alone, or in a matrix with
namespaceMatrix): clusterDecisionResource on the ACM PlacementDecisions of placement.name, or
clusters on the Argo CD cluster Secrets that match clusters.selector.
*/}}
{{- define "gitops-hub-ocm-placement-appset.memberGenerator" -}}
{{- $pn := .Values.placement.name | default "acm-openshift-gitops-placement" -}}
{{- $pdec := .Values.placement.placementDecisionName | default "" -}}
{{- if eq (include "gitops-hub-ocm-placement-appset.generator" .) "clusterDecisionResource" -}}
- clusterDecisionResource:
    configMapRef: {{ .Values.generatorConfigMap.name | quote }}
{{- if $pdec }}
    name: {{ $pdec | quote }}
{{- else }}
    labelSelector:
{{- $selector := .Values.clusterDecisionResource.labelSelector | default dict }}
{{- if $selector }}
{{- toYaml $selector | nindent 6 }}
{{- else }}
      matchLabels:
        cluster.open-cluster-management.io/placement: {{ $pn | quote }}
{{- end }}
{{- end }}
    requeueAfterSeconds: {{ .Values.clusterDecisionResource.requeueAfterSeconds }}
{{- else -}}
- clusters:
    selector:
{{- toYaml (required "clusters.selector is required: an empty selector also selects the hub (in-cluster)" .Values.clusters.selector) | nindent 6 }}
{{- end -}}
{{- end }}

{{/*
The generator parameter that holds a member's Argo CD cluster name: {{clusterName}} from a
PlacementDecision, {{name}} from a cluster Secret. Presets write {{clusterName}}.
*/}}
{{- define "gitops-hub-ocm-placement-appset.clusterParam" -}}
{{- if eq (include "gitops-hub-ocm-placement-appset.generator" .) "clusterDecisionResource" -}}
{{ "{{clusterName}}" }}
{{- else -}}
{{ "{{name}}" }}
{{- end -}}
{{- end }}

{{/*
"true" when the ApplicationSet generates one Application per mesh member. members.enabled,
or the older clusterDecisionResource.enabled, set false turns it off (hub-only presets).
*/}}
{{- define "gitops-hub-ocm-placement-appset.membersEnabled" -}}
{{- $on := eq (toString .Values.members.enabled) "true" -}}
{{- if and (hasKey .Values.clusterDecisionResource "enabled") (ne (toString .Values.clusterDecisionResource.enabled) "true") -}}
{{- $on = false -}}
{{- end -}}
{{- if $on }}true{{ end -}}
{{- end }}

{{/*
A preset helm parameter value, quoted, with {{clusterName}} in a string value replaced by the
generator's parameter. Call with (list <value> <clusterParam>).
*/}}
{{- define "gitops-hub-ocm-placement-appset.paramValue" -}}
{{- $v := index . 0 -}}
{{- if kindIs "string" $v -}}
{{- $v = replace "{{clusterName}}" (index . 1) $v -}}
{{- end -}}
{{- $v | quote -}}
{{- end }}
