#!/usr/bin/env bats
# terraform/scripts/mesh-metrics-cleanup.sh against a stub kubectl: in each listed namespace it
# deletes only the monitors and ConfigMaps with charts/spoke-mesh-metrics' label, then the
# labelled cluster-monitoring-config in openshift-monitoring; a failed delete is a warning and
# the script still exits 0; bad input fails before any call.

load test_helper

SCRIPT="${ROOT}/terraform/scripts/mesh-metrics-cleanup.sh"

setup() {
	STUB_DIR="${BATS_TEST_TMPDIR}/stub"
	STUB_LOG="${STUB_DIR}/calls.log"
	export STUB_DIR STUB_LOG
	mkdir -p "${STUB_DIR}/bin"
	: >"$STUB_LOG"
	# kubectl: delete prints what it deleted for a namespace listed in deleted.<ns>; a namespace
	# listed in the file fail makes every delete there fail.
	cat >"${STUB_DIR}/bin/kubectl" <<'EOF'
#!/usr/bin/env bash
echo "kubectl $*" >>"$STUB_LOG"
ns=""
prev=""
for a in "$@"; do
	[[ "$prev" == "-n" ]] && ns="$a"
	prev="$a"
done
if grep -qx "$ns" "$STUB_DIR/fail" 2>/dev/null; then
	echo "error: the server is currently unable to handle the request" >&2
	exit 1
fi
case " $* " in
*" delete configmaps "*) [[ -f "$STUB_DIR/deleted.$ns" ]] && echo "configmap \"$(cat "$STUB_DIR/deleted.$ns")\" deleted" ;;
esac
exit 0
EOF
	chmod +x "${STUB_DIR}/bin/kubectl"
	export PATH="${STUB_DIR}/bin:${PATH}"
	export KUBECONFIG_PATH=/dev/null KUBE_CONTEXT=member-a
	export NAMESPACES="istio-system mesh-verify"
	unset SELECTOR MONITORING_NAMESPACE
	KC="kubectl --kubeconfig=/dev/null --context=member-a"
}

@test "deletes only what carries the chart's label, in each listed namespace and then openshift-monitoring" {
	echo cluster-monitoring-config >"${STUB_DIR}/deleted.openshift-monitoring"
	run bash "$SCRIPT"
	assert_success
	assert_output --partial 'openshift-monitoring: configmap "cluster-monitoring-config" deleted'
	refute_output --partial "WARNING"
	run cat "$STUB_LOG"
	L="-l app.kubernetes.io/name=spoke-mesh-metrics --ignore-not-found --wait=false"
	assert_output "$(printf '%s\n' \
		"$KC delete podmonitors.monitoring.coreos.com -n istio-system $L" \
		"$KC delete servicemonitors.monitoring.coreos.com -n istio-system $L" \
		"$KC delete configmaps -n istio-system $L" \
		"$KC delete podmonitors.monitoring.coreos.com -n mesh-verify $L" \
		"$KC delete servicemonitors.monitoring.coreos.com -n mesh-verify $L" \
		"$KC delete configmaps -n mesh-verify $L" \
		"$KC delete configmaps -n openshift-monitoring $L")"
	# Never a delete by name or without the label: a ConfigMap of the user's own stays.
	run grep -v -- '-l app.kubernetes.io/name=spoke-mesh-metrics' "$STUB_LOG"
	assert_failure
}

@test "a failed delete is a warning naming what to check, and the script goes on and exits 0" {
	echo mesh-verify >"${STUB_DIR}/fail"
	run bash "$SCRIPT"
	assert_success
	assert_output --partial "WARNING: deleting podmonitors.monitoring.coreos.com -l app.kubernetes.io/name=spoke-mesh-metrics in mesh-verify failed"
	assert_output --partial "WARNING: 3 delete(s) failed: check by hand"
	run grep -c -- "-n openshift-monitoring" "$STUB_LOG"
	assert_output "1"
}

@test "bad input fails before any kubectl call" {
	NAMESPACES="istio-system Bad_NS" run bash "$SCRIPT"
	assert_failure
	assert_output --partial "error: not a namespace name: Bad_NS"
	NAMESPACES=" " run bash "$SCRIPT"
	assert_failure
	assert_output --partial "NAMESPACES lists no namespace"
	SELECTOR="app in (a,b)" run bash "$SCRIPT"
	assert_failure
	assert_output --partial "SELECTOR must be one <label>=<value>"
	KUBE_CONTEXT="" run bash "$SCRIPT"
	assert_failure
	assert_output --partial "set KUBECONFIG_PATH+KUBE_CONTEXT or TOKEN_SCRIPT+API_URL+ADMIN_PASS"
	run cat "$STUB_LOG"
	assert_output ""
}
