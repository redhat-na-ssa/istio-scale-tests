#!/usr/bin/env bash
set -euo pipefail

# Delete what charts/spoke-mesh-metrics left on one mesh member, on destroy (terraform/platform,
# acm_observability): its PodMonitor and allowlist ConfigMap in each listed namespace, the istiod
# ServiceMonitor, and openshift-monitoring/cluster-monitoring-config (user workload monitoring).
# A safety net for when argocd-app-cleanup.sh had to strip the Applications' finalizers, so Argo
# CD deleted nothing. Only objects that carry the chart's label (SELECTOR) go: a
# cluster-monitoring-config of your own (enable_user_workload_monitoring = false) stays, and so do
# the namespaces. Nothing found is the usual case. A failed delete is a warning and the script
# still exits 0: the destroy goes on, and the warning names what to check by hand.
#
# Auth modes (via environment variables):
#   Kubeconfig: KUBECONFIG_PATH + KUBE_CONTEXT
#   Token:      TOKEN_SCRIPT + API_URL + ADMIN_PASS
#
# Required: NAMESPACES (space-separated: acm_observability.istio_metrics_namespaces)
# Optional: SELECTOR (app.kubernetes.io/name=spoke-mesh-metrics), MONITORING_NAMESPACE
#   (openshift-monitoring)

: "${NAMESPACES:?NAMESPACES is required}"
SELECTOR="${SELECTOR:-app.kubernetes.io/name=spoke-mesh-metrics}"
MONITORING_NAMESPACE="${MONITORING_NAMESPACE:-openshift-monitoring}"

[[ "$SELECTOR" =~ ^[A-Za-z0-9][-A-Za-z0-9_./]*=[A-Za-z0-9][-A-Za-z0-9_.]*$ ]] ||
  { echo "error: SELECTOR must be one <label>=<value> (got: $SELECTOR)" >&2; exit 1; }
read -r -a NS_LIST <<<"$NAMESPACES"
for ns in ${NS_LIST[@]+"${NS_LIST[@]}"} "$MONITORING_NAMESPACE"; do
  [[ "$ns" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]] || { echo "error: not a namespace name: $ns" >&2; exit 1; }
done
((${#NS_LIST[@]})) || { echo "error: NAMESPACES lists no namespace" >&2; exit 1; }

if [[ -n "${KUBECONFIG_PATH:-}" ]] && [[ -n "${KUBE_CONTEXT:-}" ]]; then
  KC="kubectl --kubeconfig=$KUBECONFIG_PATH --context=$KUBE_CONTEXT"
elif [[ -n "${TOKEN_SCRIPT:-}" ]] && [[ -n "${API_URL:-}" ]] && [[ -n "${ADMIN_PASS:-}" ]]; then
  TOKEN=$("$TOKEN_SCRIPT" "$API_URL" "cluster-admin" "$ADMIN_PASS" | jq -r '.status.token')
  KC="kubectl --server=$API_URL --token=$TOKEN --insecure-skip-tls-verify"
else
  echo "error: set KUBECONFIG_PATH+KUBE_CONTEXT or TOKEN_SCRIPT+API_URL+ADMIN_PASS" >&2
  exit 1
fi

FAILED=0
# delete_labelled <resource> <namespace>: delete every <resource> with SELECTOR in <namespace>.
delete_labelled() {
  local out line
  if out=$($KC delete "$1" -n "$2" -l "$SELECTOR" --ignore-not-found --wait=false 2>&1); then
    while IFS= read -r line; do
      [[ -z "$line" ]] || echo "  $2: $line"
    done <<<"$out"
  else
    echo "WARNING: deleting $1 -l $SELECTOR in $2 failed: $(head -1 <<<"$out")" >&2
    FAILED=$((FAILED + 1))
  fi
}

echo "=== Deleting what is left of ${SELECTOR} ==="
for ns in "${NS_LIST[@]}"; do
  delete_labelled podmonitors.monitoring.coreos.com "$ns"
  delete_labelled servicemonitors.monitoring.coreos.com "$ns"
  delete_labelled configmaps "$ns"
done
delete_labelled configmaps "$MONITORING_NAMESPACE"

if ((FAILED)); then
  echo "WARNING: ${FAILED} delete(s) failed: check by hand with kubectl get podmonitors,servicemonitors,configmaps -A -l ${SELECTOR}" >&2
fi
echo "=== Cleanup of ${SELECTOR} complete ==="
