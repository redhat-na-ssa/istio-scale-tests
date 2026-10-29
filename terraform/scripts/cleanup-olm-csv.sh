#!/usr/bin/env bash
set -euo pipefail

# Delete an OLM Subscription and its ClusterServiceVersions on destroy.
# Deletes the Subscription first so OLM does not recreate the CSV.
# With DELETE_CRS, first deletes the operator's custom resources while the operator still runs,
# so it can finalize them (remove what it created for them). Any still there after
# CR_DELETE_TIMEOUT_SEC lose their finalizers, with a warning; what the operator would have
# removed for them may be left. An entry whose resource type is gone (CRD deleted) is skipped.
#
# Auth modes (via environment variables):
#   Kubeconfig: KUBECONFIG_PATH + KUBE_CONTEXT
#   Token:      TOKEN_SCRIPT + API_URL + ADMIN_PASS
#
# Required: SUB_NAMESPACE, SUB_NAME, PACKAGE_NAME (matched against the CSV names: for a package
#   whose CSV has another name, such as kiali-ossm's kiali-operator.v*, pass the CSV's prefix)
# Optional: DELETE_CRS (space-separated <resource>:<namespace>, e.g. kialis.kiali.io:istio-system),
#   CR_DELETE_TIMEOUT_SEC (120), POLL_SEC (5), OLM_SETTLE_SEC (10)

: "${SUB_NAMESPACE:?SUB_NAMESPACE is required}"
: "${SUB_NAME:?SUB_NAME is required}"
: "${PACKAGE_NAME:?PACKAGE_NAME is required}"
DELETE_CRS="${DELETE_CRS:-}"
CR_DELETE_TIMEOUT_SEC="${CR_DELETE_TIMEOUT_SEC:-120}"
POLL_SEC="${POLL_SEC:-5}"
OLM_SETTLE_SEC="${OLM_SETTLE_SEC:-10}"

for v in CR_DELETE_TIMEOUT_SEC POLL_SEC OLM_SETTLE_SEC; do
  [[ "${!v}" =~ ^[0-9]+$ ]] || { echo "error: $v must be a non-negative integer (got: ${!v})" >&2; exit 1; }
done
read -r -a CR_ENTRIES <<<"$DELETE_CRS"
for entry in ${CR_ENTRIES[@]+"${CR_ENTRIES[@]}"}; do
  [[ "$entry" =~ ^[a-z0-9][-.a-z0-9]*:[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]] ||
    { echo "error: DELETE_CRS entries are <resource>:<namespace> (got: $entry)" >&2; exit 1; }
done

if [[ -n "${KUBECONFIG_PATH:-}" ]] && [[ -n "${KUBE_CONTEXT:-}" ]]; then
  KC="kubectl --kubeconfig=$KUBECONFIG_PATH --context=$KUBE_CONTEXT"
elif [[ -n "${TOKEN_SCRIPT:-}" ]] && [[ -n "${API_URL:-}" ]] && [[ -n "${ADMIN_PASS:-}" ]]; then
  TOKEN=$("$TOKEN_SCRIPT" "$API_URL" "cluster-admin" "$ADMIN_PASS" | jq -r '.status.token')
  KC="kubectl --server=$API_URL --token=$TOKEN --insecure-skip-tls-verify"
else
  echo "error: set KUBECONFIG_PATH+KUBE_CONTEXT or TOKEN_SCRIPT+API_URL+ADMIN_PASS" >&2
  exit 1
fi

# no_such_type <kubectl stderr>: the server has no such resource type (its CRD is gone).
no_such_type() { [[ "$1" == *"doesn't have a resource type"* ]]; }

# delete_crs <resource> <namespace>: delete every <resource> in <namespace>, wait for the
# operator to finalize them, then strip the finalizers of any left.
delete_crs() {
  local res="$1" ns="$2" err left="" deadline name
  echo "=== Deleting every $res in $ns (the operator finalizes them) ==="
  if ! err=$($KC delete "$res" --all -n "$ns" --ignore-not-found --wait=false 2>&1 >/dev/null); then
    if no_such_type "$err"; then
      echo "No resource type $res on the server (its CRD is gone): skipped."
      return 0
    fi
    echo "warning: deleting $res in $ns failed: $(head -1 <<<"$err")" >&2
  fi
  deadline=$((SECONDS + CR_DELETE_TIMEOUT_SEC))
  while :; do
    if left=$($KC get "$res" -n "$ns" -o name 2>/dev/null); then
      if [[ -z "$left" ]]; then
        echo "No $res left in $ns."
        return 0
      fi
    else
      err=$($KC get "$res" -n "$ns" -o name 2>&1 >/dev/null) || true
      if no_such_type "$err"; then
        echo "No resource type $res on the server any more: nothing left."
        return 0
      fi
      left=""
    fi
    if ((SECONDS >= deadline)); then
      break
    fi
    sleep "$POLL_SEC"
  done
  if [[ -z "$left" ]]; then
    echo "WARNING: cannot list $res in $ns: check by hand that none is left" >&2
    return 0
  fi
  while IFS= read -r name; do
    [[ -n "$name" ]] || continue
    echo "WARNING: $name in $ns is still there after ${CR_DELETE_TIMEOUT_SEC}s: removing its finalizers (what the operator would have removed for it may be left)" >&2
    $KC patch "$name" -n "$ns" --type=merge -p '{"metadata":{"finalizers":null}}' >/dev/null ||
      echo "warning: removing the finalizers of $name in $ns failed" >&2
  done <<<"$left"
  return 0
}

for entry in ${CR_ENTRIES[@]+"${CR_ENTRIES[@]}"}; do
  delete_crs "${entry%%:*}" "${entry#*:}"
done

echo "=== Deleting Subscription $SUB_NAME in $SUB_NAMESPACE ==="
$KC delete subscription.operators.coreos.com "$SUB_NAME" -n "$SUB_NAMESPACE" --wait=false 2>/dev/null || true

echo "Waiting ${OLM_SETTLE_SEC}s for OLM to settle..."
sleep "$OLM_SETTLE_SEC"

echo "=== Deleting CSVs matching '$PACKAGE_NAME' in $SUB_NAMESPACE ==="
CSVS=$($KC get csv -n "$SUB_NAMESPACE" -o name 2>/dev/null | grep "$PACKAGE_NAME" || true)
if [ -z "$CSVS" ]; then
  echo "No CSVs matching '$PACKAGE_NAME' in $SUB_NAMESPACE — nothing to clean up."
  exit 0
fi

echo "$CSVS" | while read -r csv; do
  echo "Deleting $csv in $SUB_NAMESPACE..."
  $KC delete "$csv" -n "$SUB_NAMESPACE" --wait=false 2>/dev/null || true
done
echo "CSV cleanup complete for $PACKAGE_NAME."
