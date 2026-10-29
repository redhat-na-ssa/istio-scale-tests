#!/usr/bin/env bats
# charts/spoke-mesh-metrics, the member side of the OpenShift add-on acm_observability (one release
# per member and namespace): istiod's namespace gets user workload monitoring (a
# cluster-monitoring-config with only enableUserWorkload: true, unless switched off), the istiod
# ServiceMonitor, the Envoy PodMonitor and the ACM allowlist; any other namespace only the
# PodMonitor and the allowlist, in that namespace. In each namespace the allowlist holds exactly the
# names the monitors keep, every one an exact metric name (ACM matches names, not patterns); an
# empty or invalid namespace, or a pattern in a name list, fails the render. Needs helm; skips
# without it.

bats_require_minimum_version 1.5.0
load test_helper

CHART="${ROOT}/charts/spoke-mesh-metrics"

setup() {
	command -v helm >/dev/null 2>&1 || skip "helm not installed"
}

# render [helm args...]: the chart as member-a's Application renders it, plus the given args.
render() {
	helm template mesh-metrics "$CHART" --set clusterName=member-a "$@"
}

# objects <render>: one "<kind> <namespace>/<name>" line per rendered object, sorted.
objects() {
	awk '
		/^---/ { if (k != "") print k " " ns "/" n; k = ""; ns = ""; n = ""; next }
		/^kind: / { k = $2 }
		/^  name: / { n = $2 }
		/^  namespace: / { ns = $2 }
		END { if (k != "") print k " " ns "/" n }' <<<"$1" | tr -d '"' | LC_ALL=C sort
}

# keep_names <render of one monitor>: the names its metricRelabelings keep regex lists, one per
# line, sorted.
keep_names() {
	awk '/- sourceLabels: \[__name__\]/ { on = 1; next }
		on && /^ *regex: / { sub(/^ *regex: */, ""); gsub(/"/, ""); print; exit }' <<<"$1" |
		tr '|' '\n' | LC_ALL=C sort -u
}

# allowlist_names <render of the allowlist>: the names in its uwl_metrics_list.yaml, one per line,
# sorted.
allowlist_names() {
	awk '/^  uwl_metrics_list.yaml: \|$/ { on = 1; next } on && /^      - / { print $2 }' <<<"$1" | LC_ALL=C sort
}

@test "spoke-mesh-metrics, istiod's namespace: user workload monitoring (only enableUserWorkload), the istiod ServiceMonitor, the Envoy PodMonitor and the allowlist, nothing else" {
	local out cm sm pm
	out="$(render)"
	run objects "$out"
	assert_output "ConfigMap istio-system/observability-metrics-custom-allowlist
ConfigMap openshift-monitoring/cluster-monitoring-config
PodMonitor istio-system/mesh-metrics-istio-proxies
ServiceMonitor istio-system/mesh-metrics-istiod"
	# The overlay changes nothing (the chart runs on openshift only), and the defaults render
	# without a cluster name (helm lint, CI).
	[ "$(render -f "${CHART}/values-openshift.yaml")" == "$out" ]
	run helm template mesh-metrics "$CHART"
	assert_success

	# cluster-monitoring-config: one key, holding only enableUserWorkload: true.
	cm="$(render --show-only templates/cluster-monitoring-config.yaml)"
	run awk '/^data:$/ { on = 1; next } on' <<<"$cm"
	assert_output "  config.yaml: |
    enableUserWorkload: true"

	# istiod, by its Service's app label, which the series carry for Kiali.
	sm="$(render --show-only templates/servicemonitor-istiod.yaml)"
	grep -A2 '^  selector:$' <<<"$sm" | grep -qx '      app: istiod'
	grep -A1 '^  targetLabels:$' <<<"$sm" | grep -qx '    - app'
	grep -qx '    - port: http-monitoring' <<<"$sm"
	grep -qx '      interval: 60s' <<<"$sm"

	# Envoy: the merged-metrics path, at ACM's collection interval, and no mesh_id label.
	pm="$(render --show-only templates/podmonitor-istio-proxies.yaml)"
	grep -qx '    - path: /stats/prometheus' <<<"$pm"
	grep -qx '      interval: 60s' <<<"$pm"
	grep -A1 'sourceLabels: \[__meta_kubernetes_pod_container_name\]' <<<"$pm" | grep -qx '          regex: istio-proxy'
	! grep -q mesh_id <<<"$pm" || false
}

@test "spoke-mesh-metrics, any other namespace: only the PodMonitor and the allowlist, in that namespace" {
	run objects "$(render --set namespace=mesh-verify)"
	assert_output "ConfigMap mesh-verify/observability-metrics-custom-allowlist
PodMonitor mesh-verify/mesh-metrics-istio-proxies"
}

@test "spoke-mesh-metrics: userWorkloadMonitoring.enabled=false drops cluster-monitoring-config and nothing else" {
	run objects "$(render --set userWorkloadMonitoring.enabled=false)"
	assert_output "ConfigMap istio-system/observability-metrics-custom-allowlist
PodMonitor istio-system/mesh-metrics-istio-proxies
ServiceMonitor istio-system/mesh-metrics-istiod"
}

@test "spoke-mesh-metrics: in each namespace the allowlist names exactly what the monitors keep, every one an exact metric name; istiod's names only in istiod's namespace" {
	local ns al kept n
	for ns in istio-system mesh-verify; do
		al="$(allowlist_names "$(render --set namespace="$ns" --show-only templates/metrics-allowlist.yaml)")"
		grep -A1 '^  uwl_metrics_list.yaml: |$' <<<"$(render --set namespace="$ns" --show-only templates/metrics-allowlist.yaml)" |
			grep -qx '    names:' || { echo "$ns: the allowlist has no names: list"; false; }
		kept="$(keep_names "$(render --set namespace="$ns" --show-only templates/podmonitor-istio-proxies.yaml)")"
		if [[ "$ns" == istio-system ]]; then
			kept="$(printf '%s\n%s\n' "$kept" "$(keep_names "$(render --show-only templates/servicemonitor-istiod.yaml)")" | LC_ALL=C sort -u)"
		fi
		[[ -n "$al" ]] || { echo "$ns: the allowlist is empty"; false; }
		[[ "$al" == "$kept" ]] || { echo "$ns: the allowlist (<) and the keep regexes (>) differ:"; diff <(echo "$al") <(echo "$kept"); false; }
		while IFS= read -r n; do
			[[ "$n" =~ ^[a-zA-Z_:][a-zA-Z0-9_:]*$ ]] || { echo "$ns: ${n} is not an exact metric name"; false; }
		done <<<"$al"
	done
	grep -qx pilot_xds <<<"$(allowlist_names "$(render --show-only templates/metrics-allowlist.yaml)")"
	! grep -q '^pilot_' <<<"$(allowlist_names "$(render --set namespace=mesh-verify --show-only templates/metrics-allowlist.yaml)")" || false
}

@test "spoke-mesh-metrics: an empty or invalid namespace, or a pattern in a name list, fails the render with a message" {
	run render --set namespace=
	assert_failure
	assert_output --partial 'namespace is empty'
	run render --set namespace=Mesh_Verify
	assert_failure
	assert_output --partial 'namespace "Mesh_Verify" is not a namespace name'
	run render --set namespace="$(printf 'a%.0s' {1..64})"
	assert_failure
	assert_output --partial 'is not a namespace name'
	run render --set 'proxyMetrics={istio_.*}'
	assert_failure
	assert_output --partial 'proxyMetrics: "istio_.*" is not an exact metric name'
}
