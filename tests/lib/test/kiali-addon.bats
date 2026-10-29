#!/usr/bin/env bats
# The OpenShift add-ons (terraform/platform acm_observability, kiali_multicluster) in the charts:
# the app-of-apps renders their four child Applications only on openshift and only when enabled;
# charts/kiali gives a member's Kiali CR the hub's callback for that member as its first redirect
# URI and fails without it, and the hub's CR the external model and the metrics settings, with a
# PostSync hook that waits for every member's remote secret and reruns when the members change;
# charts/hub-kiali-remote-secret writes the secret Kiali autodetects, never labels a store for
# charts/hub-mesh-push-secrets, and renders for a 44-character member under its preset's short
# release name; the metrics preset makes one Application per member and namespace; argocd-config
# adds the Kiali health check only when asked; terraform/platform still writes the value paths
# these tests feed the charts. Needs helm; skips without it.

bats_require_minimum_version 1.5.0
load test_helper

APPSET="${ROOT}/charts/gitops-hub-ocm-placement-appset"
KIALI="${ROOT}/charts/kiali"
REMOTE_SECRET="${ROOT}/charts/hub-kiali-remote-secret"
REPO=(--set repo.url=https://example.invalid/istio-scale-tests.git --set repo.revision=main)
ADDONS="spoke-mesh-metrics-appset spoke-kiali-appset hub-kiali hub-kiali-remote-secret-appset"
BASE=https://kiali-istio-system.apps.example.invalid/api/auth/callback

setup() {
	command -v helm >/dev/null 2>&1 || skip "helm not installed"
}

# apps_render <platform> [helm args...]: charts/gitops-hub-apps on <platform>.
apps_render() {
	local p="$1"
	shift
	local ns=argocd
	[[ "$p" == openshift ]] && ns=openshift-gitops
	helm template root "${ROOT}/charts/gitops-hub-apps" "${REPO[@]}" --set "platform=${p}" --set "gitopsNamespace=${ns}" "$@"
}

# app_doc <render> <name>: the document of Application <name> in <render>.
app_doc() {
	awk -v n="  name: $2" '/^---/ { if (hit) exit; doc = ""; next } { doc = doc $0 "\n" } $0 == n { hit = 1 } END { if (hit) printf "%s", doc }' <<<"$1"
}

@test "app-of-apps: the add-on Applications are off by default, on openshift only when enabled, never on kubernetes" {
	local p out a doc on=()
	for a in $ADDONS; do on+=(--set "apps.${a}.enabled=true"); done
	for p in kubernetes openshift; do
		out="$(apps_render "$p")"
		for a in $ADDONS; do
			[[ -z "$(app_doc "$out" "$a")" ]] || { echo "$p: $a renders by default"; false; }
		done
	done
	out="$(apps_render kubernetes "${on[@]}")"
	for a in $ADDONS; do
		[[ -z "$(app_doc "$out" "$a")" ]] || { echo "kubernetes: $a renders when enabled"; false; }
	done
	out="$(apps_render openshift "${on[@]}")"
	# name, wave, preset (or chart)
	while read -r a wave src; do
		doc="$(app_doc "$out" "$a")"
		[[ -n "$doc" ]] || { echo "openshift: $a is missing"; false; }
		grep -qx "    argocd.argoproj.io/sync-wave: \"${wave}\"" <<<"$doc" || { echo "$a: not at wave ${wave}"; false; }
		if [[ "$src" == values-*.yaml ]]; then
			grep -qx "        - ${src}" <<<"$doc" || { echo "$a: not on the preset ${src}"; false; }
			grep -qx '        - platform-openshift.yaml' <<<"$doc" || { echo "$a: without platform-openshift.yaml"; false; }
		else
			grep -qx "    path: ${src}" <<<"$doc" || { echo "$a: not on ${src}"; false; }
		fi
	done <<'EOF'
spoke-mesh-metrics-appset 30 values-mesh-metrics.yaml
spoke-kiali-appset 31 values-kiali.yaml
hub-kiali 32 charts/kiali
hub-kiali-remote-secret-appset 33 values-kiali-remote-secret.yaml
EOF
	doc="$(app_doc "$out" hub-kiali)"
	grep -A1 -x '        - name: mode' <<<"$doc" | grep -qx '          value: hub'
	grep -qx '        - values-openshift.yaml' <<<"$doc"
	grep -qx '    namespace: istio-system' <<<"$doc"
	grep -qx '      - CreateNamespace=true' <<<"$doc"
}

@test "kiali remote: the member's CR has the hub's callback for it first and creates only the remote resources; the token Secret; no render without its values" {
	local out
	out="$(helm template kiali "$KIALI" -f "${KIALI}/values-openshift.yaml" --set mode=remote --set clusterName=member-a \
		--set "hubRedirectBase=${BASE}/")"
	grep -A1 -x '      redirect_uris:' <<<"$out" | grep -qx "        - \"${BASE}/member-a\""
	grep -qx '    remote_cluster_resources_only: true' <<<"$out"
	grep -qx '    view_only_mode: true' <<<"$out"
	! grep -q 'ignore_home_cluster' <<<"$out" || false
	grep -B12 -x 'type: kubernetes.io/service-account-token' <<<"$out" | grep -qx '  name: kiali-service-account'
	grep -qx '    kubernetes.io/service-account.name: kiali-service-account' <<<"$out"
	# The hub-only objects stay off the member.
	! grep -qE 'kiali-reconcile|-argocd-sync' <<<"$out" || false
	run helm template kiali "$KIALI" --set mode=remote --set clusterName=member-a
	assert_failure
	assert_output --partial 'mode remote needs hubRedirectBase'
	run helm template kiali "$KIALI" --set mode=remote --set "hubRedirectBase=${BASE}"
	assert_failure
	assert_output --partial 'mode remote needs clusterName'
	run helm template kiali "$KIALI" --set mode=member
	assert_failure
	assert_output --partial 'mode must be hub or remote, not "member"'
}

@test "kiali remote: the preset with Terraform's hubRedirectBase gives each member's CR its own callback, on both platforms" {
	local p out vals cr
	for p in kubernetes openshift; do
		out="$(helm template preset "$APPSET" -f "${APPSET}/values-kiali.yaml" -f "${APPSET}/platform-${p}.yaml" "${REPO[@]}" \
			--set "template.source.helm.valuesObject.hubRedirectBase=${BASE}")"
		grep -A1 -x '            - name: "mode"' <<<"$out" | grep -qx '              value: "remote"'
		grep -qx '          name: kiali-service-account' <<<"$out"
		vals="$(awk '/^          valuesObject:$/ { on = 1; next } on && /^            / { print substr($0, 13); next } on { exit }' <<<"$out")"
		printf '%s\n' "$vals" >"${BATS_TEST_TMPDIR}/values.yaml"
		cr="$(helm template kiali "$KIALI" -f "${BATS_TEST_TMPDIR}/values.yaml" --set mode=remote --set clusterName=member-b \
			--show-only templates/kiali-remote.yaml)"
		grep -qx "        - \"${BASE}/member-b\"" <<<"$cr" || { echo "$p: member-b's redirect URI is not ${BASE}/member-b"; false; }
	done
}

@test "kiali hub: external model, metrics settings from the values, and the PostSync hook only with members" {
	local out hook
	out="$(helm template kiali "$KIALI" -f "${KIALI}/values-openshift.yaml" --set clusterName=hub-a \
		--set prometheus.scrapeInterval=300s --set prometheus.retentionPeriod=10d)"
	grep -qx '    ignore_home_cluster: true' <<<"$out"
	grep -A1 -x '    autodetect_secrets:' <<<"$out" | grep -qx '      enabled: true'
	grep -qx '    cluster_name: "hub-a"' <<<"$out"
	grep -qx '    strategy: openshift' <<<"$out"
	grep -qx '        scrape_interval: "300s"' <<<"$out"
	grep -qx '        retention_period: "10d"' <<<"$out"
	grep -qx '      url: "http://observability-thanos-query-frontend.open-cluster-management-observability.svc:9090"' <<<"$out"
	grep -qx '  startingCSV: "kiali-operator.v2.27.5"' <<<"$out"
	# No members, no hook; the token Secret is the member's only.
	! grep -q 'kiali-reconcile' <<<"$out" || false
	! grep -q 'service-account-token' <<<"$out" || false
	hook="$(helm template kiali "$KIALI" --set-json 'remoteClusters=["member-a","member-b"]' --show-only templates/reconcile-hook.yaml)"
	grep -qx '      - "kiali-remote-cluster-secret-member-a"' <<<"$hook"
	grep -qx '      - "kiali-remote-cluster-secret-member-b"' <<<"$hook"
	grep -q 'MEMBERS=( "member-a" "member-b" )' <<<"$hook"
	[ "$(grep -c 'argocd.argoproj.io/hook: PostSync' <<<"$hook")" -eq 4 ]
	grep -q 'oc annotate kialis.kiali.io kiali -n "$NS" --overwrite "kiali.io/reconcile=${hash}"' <<<"$hook"
	# A tracked object lists the members, so a new list makes hub-kiali sync and rerun the hook.
	out="$(helm template kiali "$KIALI" --set-json 'remoteClusters=["member-a","member-b"]')"
	grep -A12 -x '  name: kiali-remote-clusters' <<<"$out" | grep -qx '  clusters: "member-a,member-b"'
	! grep -A2 -x '  name: kiali-remote-clusters' <<<"$out" | grep -q 'argocd.argoproj.io/hook' || false
}

@test "hub-kiali-remote-secret: the secret Kiali autodetects, from a store charts/hub-mesh-push-secrets never selects; nothing without the member's server" {
	local out
	# The preset's release name, shared by every member's Application on the hub.
	out="$(helm template kiali-remote-secret "$REMOTE_SECRET" -f "${REMOTE_SECRET}/values-openshift.yaml" \
		--set clusterName=member-a --set clusterServer=https://api.member-a.example.invalid:6443)"
	grep -A12 -x '  target:' <<<"$out" | grep -qx '    name: "kiali-remote-cluster-secret-member-a"'
	grep -qx '          kiali.io/multiCluster: "true"' <<<"$out"
	grep -qx '          kiali.io/cluster: "member-a"' <<<"$out"
	grep -qx '        member-a: "{{ .kubeconfig }}"' <<<"$out"
	grep -qx '                token: {{ .token }}' <<<"$out"
	grep -qx '        url: "https://api.member-a.example.invalid:6443"' <<<"$out"
	# No label of charts/hub-mesh-push-secrets (its PushSecrets select stores by them).
	! grep -qE '^ +hub-mesh-push-secrets/' <<<"$out" || false
	grep -qx '    namespace: "openshift-gitops"' <<<"$out"
	# Named from the member, not the shared release: two members' Roles never collide.
	# Role and RoleBinding (and its roleRef) in external-secrets-operator and istio-system.
	[ "$(grep -cx '  name: "kiali-member-a-argocd-sync"' <<<"$out")" -eq 6 ]
	! grep -q 'kiali-remote-secret-argocd-sync' <<<"$out" || false
	[ -z "$(helm template x "$REMOTE_SECRET" --set clusterName=member-a)" ]
	[ -z "$(helm template x "$REMOTE_SECRET" --set clusterServer=https://api.member-a.example.invalid:6443)" ]
}

@test "kiali-remote-secret preset: a short release name, so a member name of up to 44 characters renders" {
	local p out m
	m=member-0123456789-0123456789-0123456789-abcd
	[ "${#m}" -eq 44 ]
	for p in kubernetes openshift; do
		out="$(helm template preset "$APPSET" -f "${APPSET}/values-kiali-remote-secret.yaml" -f "${APPSET}/platform-${p}.yaml" "${REPO[@]}")"
		grep -qx '          releaseName: "kiali-remote-secret"' <<<"$out" || { echo "$p: no releaseName kiali-remote-secret"; false; }
	done
	# What Argo CD runs for that member: helm template --name-template <releaseName>.
	helm template --name-template kiali-remote-secret "$REMOTE_SECRET" --set "clusterName=${m}" \
		--set clusterServer=https://api.example.invalid:6443 >/dev/null
	# Without it the release would be the Application's name, which Helm refuses.
	run helm template --name-template "${m}-hub-kiali-remote-secret" "$REMOTE_SECRET" --set "clusterName=${m}" \
		--set clusterServer=https://api.example.invalid:6443
	assert_failure
	assert_output --partial 'must not be longer than 53'
}

@test "mesh-metrics preset: one Application per member and namespace, the namespace created; members and clusterName only" {
	local p out cp
	for p in kubernetes openshift; do
		out="$(helm template preset "$APPSET" -f "${APPSET}/values-mesh-metrics.yaml" -f "${APPSET}/platform-${p}.yaml" "${REPO[@]}" \
			--set-json 'namespaceMatrix.namespaces=["istio-system","mesh-verify"]')"
		cp='{{clusterName}}'
		[[ "$p" == kubernetes ]] && cp='{{name}}'
		grep -qx '    - matrix:' <<<"$out"
		[ "$(grep -c '^                - targetNamespace: ' <<<"$out")" -eq 2 ]
		grep -qx '                - targetNamespace: "istio-system"' <<<"$out"
		grep -qx '                - targetNamespace: "mesh-verify"' <<<"$out"
		grep -qxF "      name: '${cp}-mesh-metrics-{{targetNamespace}}'" <<<"$out" || { echo "$p: Application name is not ${cp}-mesh-metrics-{{targetNamespace}}"; false; }
		grep -qxF '        namespace: "{{targetNamespace}}"' <<<"$out"
		grep -A1 -xF '            - name: "namespace"' <<<"$out" | grep -qxF '              value: "{{targetNamespace}}"'
		grep -qx '          - CreateNamespace=true' <<<"$out"
	done
	run helm template preset "$APPSET" -f "${APPSET}/values-mesh-metrics.yaml" "${REPO[@]}" --set destination.mode=inClusterServer
	assert_failure
	assert_output --partial 'namespaceMatrix needs destination.mode clusterName'
	run helm template preset "$APPSET" -f "${APPSET}/values-mesh-metrics.yaml" "${REPO[@]}" --set inClusterGenerator.enabled=true
	assert_failure
	assert_output --partial 'namespaceMatrix: members only'
	run helm template preset "$APPSET" -f "${APPSET}/values-mesh-metrics.yaml" "${REPO[@]}" --set-json 'namespaceMatrix.namespaces=[]'
	assert_failure
	assert_output --partial 'namespaceMatrix.namespaces is empty'
}

@test "terraform/platform still writes the values the tests above feed the charts" {
	# The tests hand the charts copies of Terraform's values; a renamed key or path in
	# platform_kiali.tf or platform_acm_observability.tf would leave them green while every member
	# render fails (no hubRedirectBase) or falls back to the preset's defaults (istio-system only).
	local tf_kiali="${ROOT}/terraform/platform/platform_kiali.tf" tf_obs="${ROOT}/terraform/platform/platform_acm_observability.tf"
	local tf_gitops="${ROOT}/terraform/platform/platform_gitops.tf" f re
	while IFS='|' read -r f re; do
		[[ -n "$f" ]] || continue
		grep -Eq "$re" "${!f}" || { echo "${!f##*/} no longer matches /${re}/: update this test and the charts' values"; false; }
	done <<'EOF'
tf_kiali|^    "hub-kiali" = \{$
tf_kiali|^        clusterName = local\.acm_local_cluster_name$
tf_kiali|^        remoteClusters = local\.mesh_member_spoke_keys$
tf_kiali|^        viewOnly += var\.kiali_multicluster\.view_only$
tf_kiali|^        prometheus = \{$
tf_kiali|^          scrapeInterval += "\$\{var\.acm_observability\.interval_sec\}s"$
tf_kiali|^          retentionPeriod = var\.acm_observability\.retention$
tf_kiali|^    "spoke-kiali-appset" = \{$
tf_kiali|^      values = \{ template = \{ source = \{ helm = \{ valuesObject = \{$
tf_kiali|^        hubRedirectBase = local\.kiali_redirect_base$
tf_kiali|^    "hub-kiali-remote-secret-appset" = \{ enabled = true \}$
tf_obs|^    "spoke-mesh-metrics-appset" = \{$
tf_obs|^        namespaceMatrix = \{ namespaces = var\.acm_observability\.istio_metrics_namespaces \}$
tf_obs|^        template = \{ source = \{ helm = \{ valuesObject = \{$
tf_obs|^          userWorkloadMonitoring = \{ enabled = var\.acm_observability\.enable_user_workload_monitoring \}$
tf_gitops|^        name  = "argocd\.kialiHealthCheck\.enabled"$
tf_gitops|length\(local\.addon_app_defaults\) > 0 \? \[yamlencode\(\{ apps = local\.addon_app_defaults \}\)\] : \[\]
EOF
	# The same keys exist where the tests set them: the app-of-apps' apps and the charts' values.
	for f in spoke-mesh-metrics-appset spoke-kiali-appset hub-kiali hub-kiali-remote-secret-appset; do
		grep -qx "  ${f}:" "${ROOT}/charts/gitops-hub-apps/values.yaml" || { echo "gitops-hub-apps has no apps.${f}"; false; }
	done
	grep -qx 'clusterName: ""' "${KIALI}/values.yaml"
	grep -qx 'remoteClusters: \[\]' "${KIALI}/values.yaml"
	grep -qx 'hubRedirectBase: ""' "${KIALI}/values.yaml"
	grep -qx '  scrapeInterval: 60s' "${KIALI}/values.yaml"
	grep -qx '  retentionPeriod: 14d' "${KIALI}/values.yaml"
	grep -qx '  enabled: true' <(grep -A3 -x 'userWorkloadMonitoring:' "${ROOT}/charts/spoke-mesh-metrics/values.yaml")
	grep -qx '  kialiHealthCheck:' "${ROOT}/charts/argocd-config/values.yaml"
}

@test "argocd-config: the Kiali health check only when enabled" {
	local out
	out="$(helm template argocd-config "${ROOT}/charts/argocd-config")"
	! grep -q 'kiali.io' <<<"$out" || false
	grep -qx '      kind: Istio' <<<"$out"
	out="$(helm template argocd-config "${ROOT}/charts/argocd-config" --set argocd.kialiHealthCheck.enabled=true)"
	grep -A1 -x '      group: kiali.io' <<<"$out" | grep -qx '      kind: Kiali'
	grep -q 'if c.type == "Successful" and c.status == "True" then' <<<"$out"
	grep -qx '      kind: IstioCNI' <<<"$out"
}
