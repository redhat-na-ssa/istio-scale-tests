#!/usr/bin/env bats
# terraform/scripts/argocd-app-cleanup.sh against a stub kubectl. Default mode deletes only the
# root Application hub-gitops-root and waits for the rest to cascade. APP_NAMES mode (an add-on
# turned off): it waits until the root no longer renders the named children (gone, or listed
# only to prune), deletes only those, waits for them, their ApplicationSets and the
# Applications those own, and on timeout strips the finalizers of exactly those (ApplicationSets
# first) and exits 0; the root and every other Application are never touched. The stub's
# answers end each passing case; a timeout case runs with a 0 s timeout.

load test_helper

SCRIPT="${ROOT}/terraform/scripts/argocd-app-cleanup.sh"

# apps_json <name[:owner ApplicationSet]>...: an Application list.
apps_json() {
	local items="" a name owner ref
	for a in "$@"; do
		IFS=: read -r name owner <<<"$a"
		ref=""
		if [[ -n "$owner" ]]; then ref=",\"ownerReferences\":[{\"kind\":\"ApplicationSet\",\"name\":\"${owner}\"}]"; fi
		items+="${items:+,}{\"metadata\":{\"name\":\"${name}\"${ref}}}"
	done
	printf '{"items":[%s]}\n' "$items"
}

# appsets_json <name>...: an ApplicationSet list.
appsets_json() {
	local items="" s
	for s in "$@"; do items+="${items:+,}{\"metadata\":{\"name\":\"${s}\"}}"; done
	printf '{"items":[%s]}\n' "$items"
}

# root_json <name[:prune]>...: the root Application, listing these children in .status.resources
# (":prune": requiresPruning, the root no longer renders it).
root_json() {
	local res="" r name prune p
	for r in "$@"; do
		IFS=: read -r name prune <<<"$r"
		p=""
		if [[ -n "$prune" ]]; then p=',"requiresPruning":true'; fi
		res+="${res:+,}{\"group\":\"argoproj.io\",\"kind\":\"Application\",\"namespace\":\"openshift-gitops\",\"name\":\"${name}\"${p}}"
	done
	printf '{"metadata":{"name":"hub-gitops-root"},"status":{"resources":[%s]}}\n' "$res"
}

setup() {
	STUB_DIR="${BATS_TEST_TMPDIR}/stub"
	STUB_LOG="${STUB_DIR}/calls.log"
	export STUB_DIR STUB_LOG
	mkdir -p "${STUB_DIR}/bin"
	: >"$STUB_LOG"
	# kubectl: the root answers from root.<n>.json in call order (the last one repeats; none: the
	# root is gone), the Application and ApplicationSet lists from apps.<n>.json and
	# appsets.<n>.json the same way (none: empty), the default mode's name lists from apps.names
	# and appsets.names; delete and patch succeed. With notype, every get fails as when Argo
	# CD's CRDs are gone.
	cat >"${STUB_DIR}/bin/kubectl" <<'EOF'
#!/usr/bin/env bash
echo "kubectl $*" >>"$STUB_LOG"
if [[ -f "$STUB_DIR/notype" && " $* " == *" get "* ]]; then
	echo "error: the server doesn't have a resource type \"applications\"" >&2
	exit 1
fi
# answer <prefix>: the next of <prefix>.<n>.json in call order, the last one repeating.
answer() {
	local n f
	n=$(( $(cat "$STUB_DIR/$1.n" 2>/dev/null || echo 0) + 1 ))
	echo "$n" >"$STUB_DIR/$1.n"
	f="$STUB_DIR/$1.${n}.json"
	[[ -f "$f" ]] || f="$(ls "$STUB_DIR"/"$1".*.json 2>/dev/null | sort -t. -k2 -n | tail -1)"
	if [[ -n "$f" ]]; then cat "$f"; elif [[ -n "${2:-}" ]]; then echo "$2"; fi
}
case " $* " in
*" get applications.argoproj.io hub-gitops-root "*) answer root ;;
*" get applications.argoproj.io "*" -o json "*) answer apps '{"items":[]}' ;;
*" get applicationsets.argoproj.io "*" -o json "*) answer appsets '{"items":[]}' ;;
*" get applications.argoproj.io "*" -o jsonpath="*) cat "$STUB_DIR/apps.names" 2>/dev/null || true ;;
*" get applicationsets.argoproj.io "*" -o jsonpath="*) cat "$STUB_DIR/appsets.names" 2>/dev/null || true ;;
*" delete "* | *" patch "*) ;;
*) exit 1 ;;
esac
EOF
	chmod +x "${STUB_DIR}/bin/kubectl"
	export PATH="${STUB_DIR}/bin:${PATH}"
	export KUBECONFIG_PATH=/dev/null KUBE_CONTEXT=hub GITOPS_NS=openshift-gitops
	export POLL_SEC=0 ROOT_WAIT_SEC=60 TIMEOUT_SEC=60
	unset APP_NAMES APPSET_NAMES ROOT_APP
}

@test "default mode deletes only hub-gitops-root, waits for the cascade, and strips what is left after TIMEOUT_SEC" {
	run bash "$SCRIPT"
	assert_success
	assert_output --partial "All Applications and ApplicationSets removed."
	run grep -E ' (delete|patch) ' "$STUB_LOG"
	assert_output "kubectl --kubeconfig=/dev/null --context=hub delete application.argoproj.io hub-gitops-root -n openshift-gitops --wait=false"

	: >"$STUB_LOG"
	echo "app-a app-b" >"${STUB_DIR}/apps.names"
	echo "set-a" >"${STUB_DIR}/appsets.names"
	run env TIMEOUT_SEC=0 bash "$SCRIPT"
	assert_success
	assert_output --partial "(timeout: 0s)"
	assert_output --partial "WARNING: Timeout. Force-clearing finalizers on remaining resources..."
	run grep -c ' patch application.argoproj.io app-[ab] ' "$STUB_LOG"
	assert_output "2"
	run grep -c ' delete applicationset.argoproj.io set-a ' "$STUB_LOG"
	assert_output "1"
}

@test "APP_NAMES: waits until the root no longer renders them, deletes only those, then waits for their ApplicationSets and owned Applications" {
	export APP_NAMES="hub-kiali spoke-kiali-appset" APPSET_NAMES="spoke-kiali"
	# The apply has not reached the root yet, then it lists both children only to prune.
	root_json hub-kiali spoke-kiali-appset spoke-ossm-appset >"${STUB_DIR}/root.1.json"
	root_json hub-kiali:prune spoke-kiali-appset:prune spoke-ossm-appset >"${STUB_DIR}/root.2.json"
	apps_json hub-gitops-root spoke-ossm-appset hub-kiali spoke-kiali-appset member-a-kiali:spoke-kiali \
		member-a-ossm:spoke-ossm >"${STUB_DIR}/apps.1.json"
	apps_json hub-gitops-root spoke-ossm-appset member-a-kiali:spoke-kiali member-a-ossm:spoke-ossm >"${STUB_DIR}/apps.2.json"
	apps_json hub-gitops-root spoke-ossm-appset member-a-ossm:spoke-ossm >"${STUB_DIR}/apps.3.json"
	appsets_json spoke-kiali spoke-ossm >"${STUB_DIR}/appsets.1.json"
	appsets_json spoke-ossm >"${STUB_DIR}/appsets.2.json"
	run bash "$SCRIPT"
	assert_success
	assert_output --partial "hub-gitops-root still renders: hub-kiali spoke-kiali-appset"
	assert_output --partial "hub-gitops-root is gone or no longer renders them."
	assert_output --partial "left: ApplicationSet/spoke-kiali Application/hub-kiali Application/spoke-kiali-appset Application/member-a-kiali"
	assert_output --partial "left: Application/member-a-kiali"
	assert_output --partial "All removed."
	refute_output --partial "WARNING"
	# Only the two named Applications are deleted, after the second read of the root.
	run grep -E ' (delete|patch) ' "$STUB_LOG"
	assert_output "$(printf 'kubectl --kubeconfig=/dev/null --context=hub delete applications.argoproj.io %s -n openshift-gitops --ignore-not-found --wait=false\n' hub-kiali spoke-kiali-appset)"
	first_delete="$(grep -n ' delete ' "$STUB_LOG" | head -1 | cut -d: -f1)"
	[ "$(head -n "$first_delete" "$STUB_LOG" | grep -c ' get applications.argoproj.io hub-gitops-root ')" -eq 2 ]
}

@test "APP_NAMES: a gone root lets it delete at once; on timeout it strips only the named and owned ones, ApplicationSets first, and exits 0" {
	export APP_NAMES="hub-kiali spoke-kiali-appset" APPSET_NAMES="spoke-kiali" TIMEOUT_SEC=0
	apps_json hub-gitops-root other-app hub-kiali member-a-kiali:spoke-kiali member-a-other:other-set >"${STUB_DIR}/apps.1.json"
	appsets_json spoke-kiali other-set >"${STUB_DIR}/appsets.1.json"
	run bash "$SCRIPT"
	assert_success
	assert_output --partial "hub-gitops-root is gone or no longer renders them."
	assert_output --partial "WARNING: not gone within 0s: removed the finalizers of and deleted ApplicationSet/spoke-kiali Application/hub-kiali Application/member-a-kiali."
	run grep ' patch ' "$STUB_LOG"
	assert_output "$(printf 'kubectl --kubeconfig=/dev/null --context=hub patch %s -n openshift-gitops --type=merge -p {"metadata":{"finalizers":null}}\n' \
		"applicationsets.argoproj.io spoke-kiali" "applications.argoproj.io hub-kiali" "applications.argoproj.io member-a-kiali")"
	run grep -E ' (delete|patch) [a-z.]+ (hub-gitops-root|other-app|other-set|member-a-other) ' "$STUB_LOG"
	assert_failure
}

@test "APP_NAMES: a root that still renders them after ROOT_WAIT_SEC is warned about, a missing Argo CD is nothing left, and bad input is refused" {
	export APP_NAMES="hub-kiali" ROOT_WAIT_SEC=0
	root_json hub-kiali >"${STUB_DIR}/root.1.json"
	run bash "$SCRIPT"
	assert_success
	assert_output --partial "WARNING: after 0s, hub-gitops-root still renders: hub-kiali; deleting anyway"
	assert_output --partial "All removed."
	run grep -c ' delete applications.argoproj.io hub-kiali ' "$STUB_LOG"
	assert_output "1"

	run env APP_NAMES="hub-kiali Bad_Name" bash "$SCRIPT"
	assert_failure
	assert_output --partial "not an Application or ApplicationSet name: Bad_Name"
	# Argo CD already uninstalled: nothing to wait for.
	touch "${STUB_DIR}/notype"
	run env TIMEOUT_SEC=60 ROOT_WAIT_SEC=60 bash "$SCRIPT"
	assert_success
	assert_output --partial "hub-gitops-root is gone or no longer renders them."
	assert_output --partial "All removed."
	rm -f "${STUB_DIR}/notype"

	run env -u APP_NAMES APPSET_NAMES=spoke-kiali bash "$SCRIPT"
	assert_failure
	assert_output --partial "APPSET_NAMES needs APP_NAMES"
	run env POLL_SEC=x bash "$SCRIPT"
	assert_failure
	assert_output --partial "POLL_SEC must be a non-negative integer"
}
