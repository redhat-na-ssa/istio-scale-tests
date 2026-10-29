#!/usr/bin/env bash
set -euo pipefail

# Delete ACM Observability's MultiClusterObservability on destroy (terraform/platform,
# acm_observability) and wait until it and every ObservabilityAddon are gone. Deleting the MCO
# makes ACM remove the observability add-on from every managed cluster, which needs each cluster
# still attached, so this runs before the spokes are detached and before the
# open-cluster-management-observability namespace and its Secrets go. helm uninstall has
# usually deleted the MCO already; the delete here then finds nothing. A resource type the
# server no longer has (CRD gone) counts as gone; any other read error keeps waiting. Prints
# progress whenever it changes. Fails after TIMEOUT_SEC, naming what is left and how to look at
# it: the destroy stops there, before the namespace and the spokes go.
#
# Auth modes (via environment variables):
#   Kubeconfig: KUBECONFIG_PATH + KUBE_CONTEXT
#   Token:      TOKEN_SCRIPT + API_URL + ADMIN_PASS
#
# Optional: MCO_NAME (observability), TIMEOUT_SEC (900), POLL_SEC (15)

MCO_NAME="${MCO_NAME:-observability}"
TIMEOUT_SEC="${TIMEOUT_SEC:-900}"
POLL_SEC="${POLL_SEC:-15}"

for v in TIMEOUT_SEC POLL_SEC; do
  [[ "${!v}" =~ ^[0-9]+$ ]] || { echo "error: $v must be a non-negative integer (got: ${!v})" >&2; exit 1; }
done
[[ "$MCO_NAME" =~ ^[a-z0-9]([-.a-z0-9]*[a-z0-9])?$ ]] || { echo "error: MCO_NAME must be a resource name (got: $MCO_NAME)" >&2; exit 1; }

if [[ -n "${KUBECONFIG_PATH:-}" ]] && [[ -n "${KUBE_CONTEXT:-}" ]]; then
  KC=(kubectl "--kubeconfig=$KUBECONFIG_PATH" "--context=$KUBE_CONTEXT" --request-timeout=60s)
  CTX_FLAG="--context ${KUBE_CONTEXT} "
elif [[ -n "${TOKEN_SCRIPT:-}" ]] && [[ -n "${API_URL:-}" ]] && [[ -n "${ADMIN_PASS:-}" ]]; then
  TOKEN=$("$TOKEN_SCRIPT" "$API_URL" "cluster-admin" "$ADMIN_PASS" | jq -r '.status.token')
  KC=(kubectl "--server=$API_URL" "--token=$TOKEN" --insecure-skip-tls-verify --request-timeout=60s)
  CTX_FLAG="--context <hub-ctx> "
else
  echo "error: set KUBECONFIG_PATH+KUBE_CONTEXT or TOKEN_SCRIPT+API_URL+ADMIN_PASS" >&2
  exit 1
fi

MCO_RES="multiclusterobservabilities.observability.open-cluster-management.io"
ADDON_RES="observabilityaddons.observability.open-cluster-management.io"

# no_such_type <kubectl stderr>: the server has no such resource type (its CRD is gone).
no_such_type() { [[ "$1" == *"doesn't have a resource type"* ]]; }

# names <kubectl get args>...: what the get lists (-o name), nothing when the type is gone.
# Fails on any other read error.
names() {
  local out err
  if out=$("${KC[@]}" get "$@" -o name 2>/dev/null); then
    printf '%s' "$out"
    return 0
  fi
  err=$("${KC[@]}" get "$@" -o name 2>&1 >/dev/null) || true
  no_such_type "$err"
}

echo "=== Deleting MultiClusterObservability ${MCO_NAME} ==="
if ! err=$("${KC[@]}" delete "$MCO_RES" "$MCO_NAME" --ignore-not-found --wait=false 2>&1 >/dev/null); then
  if no_such_type "$err"; then
    echo "  No MultiClusterObservability resource type on the server (ACM's CRDs are gone)."
  else
    echo "warning: deleting MultiClusterObservability ${MCO_NAME} failed: $(head -1 <<<"$err")" >&2
  fi
fi

echo "=== Waiting until it and every ObservabilityAddon are gone (up to ${TIMEOUT_SEC}s) ==="
deadline=$((SECONDS + TIMEOUT_SEC))
last=""
while :; do
  if mco=$(names "$MCO_RES" "$MCO_NAME" --ignore-not-found); then
    if [[ -n "$mco" ]]; then mco_state="present"; else mco_state="gone"; fi
  else
    mco_state="unreadable"
  fi
  if addons=$(names "$ADDON_RES" -A); then
    addon_state="$(grep -c . <<<"$addons" || true)"
  else
    addon_state="unreadable"
  fi
  if [[ "$mco_state" == gone && "$addon_state" == 0 ]]; then
    echo "  MultiClusterObservability ${MCO_NAME} and every ObservabilityAddon are gone."
    exit 0
  fi
  key="MultiClusterObservability ${MCO_NAME}: ${mco_state}; ObservabilityAddons left: ${addon_state}"
  if [[ "$key" != "$last" ]]; then
    echo "  $key"
    last="$key"
  fi
  if ((SECONDS >= deadline)); then
    break
  fi
  sleep "$POLL_SEC"
done

where=""
if [[ "$addon_state" != 0 && "$addon_state" != unreadable ]]; then
  where="$("${KC[@]}" get "$ADDON_RES" -A -o jsonpath='{range .items[*]}{.metadata.namespace}{" "}{end}' 2>/dev/null)" || where=""
fi
{
  echo "error: not gone within ${TIMEOUT_SEC}s: ${key}${where:+ (in: ${where% })}"
  echo "  Inspect: kubectl ${CTX_FLAG}get multiclusterobservability ${MCO_NAME} -o yaml"
  echo "           kubectl ${CTX_FLAG}get observabilityaddons -A"
  echo "  The destroy stops here, before the observability namespace and the spokes go. The usual"
  echo "  cause is a managed cluster that cannot remove its add-on (unreachable, or its add-on agent"
  echo "  down): fix that, then run terraform destroy again."
} >&2
exit 1
