#!/usr/bin/env bats
# terraform/scripts/cleanup-olm-csv.sh against a stub kubectl. Without DELETE_CRS it makes the
# same calls as before: delete the Subscription, then the CSVs named after the package. With
# DELETE_CRS it first deletes the operator's custom resources while the operator still runs,
# waits for them, strips the finalizers of any left, and only then deletes the Subscription; an
# entry whose CRD is gone is skipped.

load test_helper

SCRIPT="${ROOT}/terraform/scripts/cleanup-olm-csv.sh"

setup() {
	STUB_DIR="${BATS_TEST_TMPDIR}/stub"
	STUB_LOG="${STUB_DIR}/calls.log"
	export STUB_DIR STUB_LOG
	mkdir -p "${STUB_DIR}/bin"
	: >"$STUB_LOG"
	# kubectl: the CSV names come from csvs, the Kiali CRs from crs.<n> in call order (the last
	# one repeats; none: no CR left); with notype, every call on kialis.kiali.io fails as when the
	# CRD is gone. delete and patch succeed.
	cat >"${STUB_DIR}/bin/kubectl" <<'EOF'
#!/usr/bin/env bash
echo "kubectl $*" >>"$STUB_LOG"
case " $* " in
*" kialis.kiali.io "*)
	if [[ -f "$STUB_DIR/notype" ]]; then
		echo "error: the server doesn't have a resource type \"kialis\"" >&2
		exit 1
	fi
	case " $* " in
	*" get "*)
		n=$(( $(cat "$STUB_DIR/crs.n" 2>/dev/null || echo 0) + 1 ))
		echo "$n" >"$STUB_DIR/crs.n"
		f="$STUB_DIR/crs.${n}"
		[[ -f "$f" ]] || f="$(ls "$STUB_DIR"/crs.[0-9]* 2>/dev/null | sort -t. -k2 -n | tail -1)"
		if [[ -n "$f" ]]; then cat "$f"; fi ;;
	esac ;;
*" get csv "*) cat "$STUB_DIR/csvs" 2>/dev/null || true ;;
*" delete "* | *" patch "*) ;;
*) exit 1 ;;
esac
EOF
	chmod +x "${STUB_DIR}/bin/kubectl"
	export PATH="${STUB_DIR}/bin:${PATH}"
	export KUBECONFIG_PATH=/dev/null KUBE_CONTEXT=member-a
	export SUB_NAMESPACE=kiali-operator SUB_NAME=kiali-ossm PACKAGE_NAME=kiali-operator
	export OLM_SETTLE_SEC=0 POLL_SEC=0 CR_DELETE_TIMEOUT_SEC=60
	unset DELETE_CRS
	KC="kubectl --kubeconfig=/dev/null --context=member-a"
}

@test "without DELETE_CRS: the Subscription, then the CSVs named after the package, as before" {
	export SUB_NAMESPACE=openshift-operators SUB_NAME=servicemeshoperator3 PACKAGE_NAME=servicemeshoperator3
	printf '%s\n' clusterserviceversion.operators.coreos.com/servicemeshoperator3.v3.4.3 \
		clusterserviceversion.operators.coreos.com/other-operator.v1.0.0 >"${STUB_DIR}/csvs"
	run bash "$SCRIPT"
	assert_success
	assert_output --partial "Waiting 0s for OLM to settle..."
	assert_output --partial "CSV cleanup complete for servicemeshoperator3."
	run cat "$STUB_LOG"
	assert_output "$(printf '%s\n' \
		"$KC delete subscription.operators.coreos.com servicemeshoperator3 -n openshift-operators --wait=false" \
		"$KC get csv -n openshift-operators -o name" \
		"$KC delete clusterserviceversion.operators.coreos.com/servicemeshoperator3.v3.4.3 -n openshift-operators --wait=false")"
}

@test "DELETE_CRS: the custom resources are deleted and waited for before the Subscription; any left lose their finalizers first" {
	export DELETE_CRS="kialis.kiali.io:istio-system"
	# kiali-ossm's CSV is named after the operator: PACKAGE_NAME is kiali-operator.
	echo clusterserviceversion.operators.coreos.com/kiali-operator.v2.27.5 >"${STUB_DIR}/csvs"
	# The operator finalizes the CR after one poll.
	echo kiali.kiali.io/kiali >"${STUB_DIR}/crs.1"
	: >"${STUB_DIR}/crs.2"
	run bash "$SCRIPT"
	assert_success
	assert_output --partial "No kialis.kiali.io left in istio-system."
	refute_output --partial "WARNING"
	run grep -c ' patch ' "$STUB_LOG"
	assert_output "0"
	del="$(grep -n " delete kialis.kiali.io --all -n istio-system --ignore-not-found --wait=false" "$STUB_LOG" | cut -d: -f1)"
	sub="$(grep -n ' delete subscription.operators.coreos.com kiali-ossm ' "$STUB_LOG" | cut -d: -f1)"
	[ -n "$del" ]
	[ -n "$sub" ]
	((del < sub))
	run grep -c " delete clusterserviceversion.operators.coreos.com/kiali-operator.v2.27.5 -n kiali-operator " "$STUB_LOG"
	assert_output "1"

	# A CR the operator never finalizes: its finalizers go after CR_DELETE_TIMEOUT_SEC, still
	# before the Subscription.
	rm -f "${STUB_DIR}"/crs.*
	: >"$STUB_LOG"
	echo kiali.kiali.io/kiali >"${STUB_DIR}/crs.1"
	run env CR_DELETE_TIMEOUT_SEC=0 bash "$SCRIPT"
	assert_success
	assert_output --partial "WARNING: kiali.kiali.io/kiali in istio-system is still there after 0s: removing its finalizers"
	patch="$(grep -n ' patch kiali.kiali.io/kiali -n istio-system --type=merge -p {"metadata":{"finalizers":null}}' "$STUB_LOG" | cut -d: -f1)"
	sub="$(grep -n ' delete subscription.operators.coreos.com kiali-ossm ' "$STUB_LOG" | cut -d: -f1)"
	[ -n "$patch" ]
	[ -n "$sub" ]
	((patch < sub))
}

@test "DELETE_CRS: an entry whose CRD is gone is skipped, and a malformed entry is refused" {
	export DELETE_CRS="kialis.kiali.io:istio-system"
	touch "${STUB_DIR}/notype"
	run bash "$SCRIPT"
	assert_success
	assert_output --partial "No resource type kialis.kiali.io on the server (its CRD is gone): skipped."
	run grep -cE ' (get|patch) kiali' "$STUB_LOG"
	assert_output "0"
	run grep -c ' delete subscription.operators.coreos.com kiali-ossm ' "$STUB_LOG"
	assert_output "1"

	run env DELETE_CRS="kialis.kiali.io" bash "$SCRIPT"
	assert_failure
	assert_output --partial "DELETE_CRS entries are <resource>:<namespace> (got: kialis.kiali.io)"
}
