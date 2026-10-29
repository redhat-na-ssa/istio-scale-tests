#!/usr/bin/env bats
# terraform/scripts/acm-observability-delete-wait.sh against a stub kubectl: it deletes the
# MultiClusterObservability and waits until it and every ObservabilityAddon are gone; a
# missing CRD counts as gone, any other read error keeps it waiting; an MCO that stays fails it
# at the deadline, naming what is left and how to look at it. The stub's answers end each
# passing case; a failing case runs with a 0 s timeout.

load test_helper

SCRIPT="${ROOT}/terraform/scripts/acm-observability-delete-wait.sh"

setup() {
	STUB_DIR="${BATS_TEST_TMPDIR}/stub"
	STUB_LOG="${STUB_DIR}/calls.log"
	export STUB_DIR STUB_LOG
	mkdir -p "${STUB_DIR}/bin"
	: >"$STUB_LOG"
	# kubectl: with notype, every call on either resource fails as when ACM's CRDs are gone.
	# The MCO read fails for the first mco.fails calls, then lists mco.left (none: gone); the
	# ObservabilityAddons answer from addons.<n> in call order (the last one repeats; none: none
	# left) and their namespaces from addons.ns. delete succeeds.
	cat >"${STUB_DIR}/bin/kubectl" <<'EOF'
#!/usr/bin/env bash
echo "kubectl $*" >>"$STUB_LOG"
args=" $* "
case "$args" in
*" multiclusterobservabilities."* | *" observabilityaddons."*)
	if [[ -f "$STUB_DIR/notype" ]]; then
		echo "error: the server doesn't have a resource type \"multiclusterobservabilities\"" >&2
		exit 1
	fi ;;
esac
case "$args" in
*" delete "*) ;;
*" get multiclusterobservabilities."*)
	n=$(( $(cat "$STUB_DIR/mco.n" 2>/dev/null || echo 0) + 1 ))
	echo "$n" >"$STUB_DIR/mco.n"
	if ((n <= $(cat "$STUB_DIR/mco.fails" 2>/dev/null || echo 0))); then
		echo "error: Unable to connect to the server" >&2
		exit 1
	fi
	cat "$STUB_DIR/mco.left" 2>/dev/null || true ;;
*" get observabilityaddons."*" -o jsonpath="*) cat "$STUB_DIR/addons.ns" 2>/dev/null || true ;;
*" get observabilityaddons."*)
	n=$(( $(cat "$STUB_DIR/addons.n" 2>/dev/null || echo 0) + 1 ))
	echo "$n" >"$STUB_DIR/addons.n"
	f="$STUB_DIR/addons.${n}"
	[[ -f "$f" ]] || f="$(ls "$STUB_DIR"/addons.[0-9]* 2>/dev/null | sort -t. -k2 -n | tail -1)"
	if [[ -n "$f" ]]; then cat "$f"; fi ;;
*) exit 1 ;;
esac
EOF
	chmod +x "${STUB_DIR}/bin/kubectl"
	export PATH="${STUB_DIR}/bin:${PATH}"
	export KUBECONFIG_PATH=/dev/null KUBE_CONTEXT=hub
	export POLL_SEC=0 TIMEOUT_SEC=60
	unset MCO_NAME
}

ADDON="observabilityaddon.observability.open-cluster-management.io/observability-addon"

@test "deletes the MCO and passes once it and every ObservabilityAddon are gone" {
	run bash "$SCRIPT"
	assert_success
	assert_output --partial "MultiClusterObservability observability and every ObservabilityAddon are gone."
	run grep ' delete ' "$STUB_LOG"
	assert_output "kubectl --kubeconfig=/dev/null --context=hub --request-timeout=60s delete multiclusterobservabilities.observability.open-cluster-management.io observability --ignore-not-found --wait=false"
	run grep -c ' get observabilityaddons.observability.open-cluster-management.io -A -o name' "$STUB_LOG"
	assert_output "1"
}

@test "waits while ObservabilityAddons linger, printing each change" {
	printf '%s\n' "$ADDON" "$ADDON" >"${STUB_DIR}/addons.1"
	echo "$ADDON" >"${STUB_DIR}/addons.2"
	: >"${STUB_DIR}/addons.3"
	run bash "$SCRIPT"
	assert_success
	assert_output --partial "MultiClusterObservability observability: gone; ObservabilityAddons left: 2"
	assert_output --partial "MultiClusterObservability observability: gone; ObservabilityAddons left: 1"
	assert_output --partial "and every ObservabilityAddon are gone."
	run cat "${STUB_DIR}/addons.n"
	assert_output "3"
}

@test "an MCO that stays fails at the deadline, naming what is left and how to inspect it" {
	echo "multiclusterobservability.observability.open-cluster-management.io/observability" >"${STUB_DIR}/mco.left"
	echo "$ADDON" >"${STUB_DIR}/addons.1"
	echo "member-a " >"${STUB_DIR}/addons.ns"
	run env TIMEOUT_SEC=0 bash "$SCRIPT"
	assert_failure
	assert_output --partial "error: not gone within 0s: MultiClusterObservability observability: present; ObservabilityAddons left: 1 (in: member-a)"
	assert_output --partial "Inspect: kubectl --context hub get multiclusterobservability observability -o yaml"
	assert_output --partial "kubectl --context hub get observabilityaddons -A"
	assert_output --partial "The destroy stops here"
}

@test "a missing CRD counts as gone; any other read error keeps it waiting" {
	touch "${STUB_DIR}/notype"
	run bash "$SCRIPT"
	assert_success
	assert_output --partial "No MultiClusterObservability resource type on the server"
	assert_output --partial "and every ObservabilityAddon are gone."

	rm -f "${STUB_DIR}/notype"
	: >"$STUB_LOG"
	# The first poll reads the MCO twice (the second time for the error), both fail.
	echo 2 >"${STUB_DIR}/mco.fails"
	run bash "$SCRIPT"
	assert_success
	assert_output --partial "MultiClusterObservability observability: unreadable; ObservabilityAddons left: 0"
	assert_output --partial "and every ObservabilityAddon are gone."
	run env TIMEOUT_SEC=x bash "$SCRIPT"
	assert_failure
	assert_output --partial "TIMEOUT_SEC must be a non-negative integer"
}
