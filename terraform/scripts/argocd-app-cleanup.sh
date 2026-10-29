#!/usr/bin/env bash
set -euo pipefail

# Cascade-delete Argo CD Applications and ApplicationSets before terraform destroy.
#
# Default: delete the root Application hub-gitops-root (its finalizer cascades to every child)
#   and wait up to TIMEOUT_SEC until no Application or ApplicationSet is left in GITOPS_NS;
#   then strip the finalizers of what is left and delete it.
# APP_NAMES set (an add-on turned off in terraform/platform): delete only these child
#   Applications of ROOT_APP. The root syncs with prune: false, so they outlive the apply that
#   stopped rendering them. First wait (up to ROOT_WAIT_SEC) until ROOT_APP is gone or lists
#   none of them in .status.resources other than to prune, so its self-heal cannot recreate
#   them. Their finalizers cascade to the ApplicationSets they deploy (APPSET_NAMES) and the
#   Applications those generate, whose PreDelete hooks run first. Wait up to TIMEOUT_SEC until
#   none of APP_NAMES, APPSET_NAMES or the Applications those own is left; on timeout strip
#   the finalizers of what is left of them (only those), delete it, warn and exit 0: the next
#   destroy step is the safety net. Never touches ROOT_APP or any other Application. A resource
#   type the server no longer has (Argo CD uninstalled) counts as nothing left.
#
# Auth modes (via environment variables):
#   Kubeconfig: KUBECONFIG_PATH + KUBE_CONTEXT
#   Token:      TOKEN_SCRIPT + API_URL + ADMIN_PASS
#
# Required: GITOPS_NS
# Optional: APP_NAMES, APPSET_NAMES (space-separated names), ROOT_APP (hub-gitops-root),
#   ROOT_WAIT_SEC (300), TIMEOUT_SEC (600), POLL_SEC (10)

: "${GITOPS_NS:?GITOPS_NS is required}"
APP_NAMES="${APP_NAMES:-}"
APPSET_NAMES="${APPSET_NAMES:-}"
ROOT_APP="${ROOT_APP:-hub-gitops-root}"
ROOT_WAIT_SEC="${ROOT_WAIT_SEC:-300}"
TIMEOUT_SEC="${TIMEOUT_SEC:-600}"
POLL_SEC="${POLL_SEC:-10}"

for v in ROOT_WAIT_SEC TIMEOUT_SEC POLL_SEC; do
  [[ "${!v}" =~ ^[0-9]+$ ]] || { echo "error: $v must be a non-negative integer (got: ${!v})" >&2; exit 1; }
done
read -r -a NAMED_APPS <<<"$APP_NAMES"
read -r -a NAMED_APPSETS <<<"$APPSET_NAMES"
for n in "$ROOT_APP" ${NAMED_APPS[@]+"${NAMED_APPS[@]}"} ${NAMED_APPSETS[@]+"${NAMED_APPSETS[@]}"}; do
  [[ "$n" =~ ^[a-z0-9]([-.a-z0-9]*[a-z0-9])?$ ]] || { echo "error: not an Application or ApplicationSet name: $n" >&2; exit 1; }
done
if ((${#NAMED_APPSETS[@]})) && ((${#NAMED_APPS[@]} == 0)); then
  echo "error: APPSET_NAMES needs APP_NAMES (the Applications that deploy them)" >&2
  exit 1
fi

if [[ -n "${KUBECONFIG_PATH:-}" ]] && [[ -n "${KUBE_CONTEXT:-}" ]]; then
  KC="kubectl --kubeconfig=$KUBECONFIG_PATH --context=$KUBE_CONTEXT"
elif [[ -n "${TOKEN_SCRIPT:-}" ]] && [[ -n "${API_URL:-}" ]] && [[ -n "${ADMIN_PASS:-}" ]]; then
  TOKEN=$("$TOKEN_SCRIPT" "$API_URL" "cluster-admin" "$ADMIN_PASS" | jq -r '.status.token')
  KC="kubectl --server=$API_URL --token=$TOKEN --insecure-skip-tls-verify"
else
  echo "error: set KUBECONFIG_PATH+KUBE_CONTEXT or TOKEN_SCRIPT+API_URL+ADMIN_PASS" >&2
  exit 1
fi

# json_list <name>...: the names as a JSON array.
json_list() {
  if (($#)); then printf '%s\n' "$@" | jq -R . | jq -sc .; else echo '[]'; fi
}

# kc_json <get args>...: kubectl get ... -o json; nothing when the resource type is gone (Argo CD
# uninstalled). Fails on any other error.
kc_json() {
  local out err
  if out=$($KC get "$@" -o json 2>/dev/null); then
    printf '%s' "$out"
    return 0
  fi
  err=$($KC get "$@" -o json 2>&1 >/dev/null) || true
  [[ "$err" == *"doesn't have a resource type"* ]]
}

# root_wants: the APP_NAMES that ROOT_APP still lists to sync (not to prune), space-separated;
# nothing once the root is gone. Fails when the root cannot be read.
root_wants() {
  local root
  root=$(kc_json applications.argoproj.io "$ROOT_APP" -n "$GITOPS_NS" --ignore-not-found) || return 1
  [[ -n "$root" ]] || return 0
  jq -r --argjson names "$APPS_JSON" '
    [.status.resources[]?
      | select(.group == "argoproj.io" and .kind == "Application" and ((.requiresPruning // false) | not))
      | .name
      | select(. as $n | $names | index($n) != null)]
    | unique | join(" ")' <<<"$root"
}

# left: what of APPSET_NAMES, APP_NAMES and the Applications those ApplicationSets own still
# exists, as space-separated "ApplicationSet/<name>" and "Application/<name>" (ApplicationSets
# first). ROOT_APP is never listed. Fails when either list cannot be read.
left() {
  local apps sets a s out
  apps=$(kc_json applications.argoproj.io -n "$GITOPS_NS") || return 1
  sets=$(kc_json applicationsets.argoproj.io -n "$GITOPS_NS") || return 1
  if [[ -z "$apps" ]]; then apps='{"items":[]}'; fi
  if [[ -z "$sets" ]]; then sets='{"items":[]}'; fi
  s=$(jq -r --argjson sets "$APPSETS_JSON" '
    [.items[] | .metadata.name | select(. as $n | $sets | index($n) != null) | "ApplicationSet/" + .]
    | join(" ")' <<<"$sets") || return 1
  a=$(jq -r --argjson apps "$APPS_JSON" --argjson sets "$APPSETS_JSON" --arg root "$ROOT_APP" '
    [.items[]
      | select(.metadata.name != $root)
      | select((.metadata.name as $n | $apps | index($n) != null)
          or ([.metadata.ownerReferences[]?
                | select(.kind == "ApplicationSet" and (.name as $o | $sets | index($o) != null))] | length > 0))
      | "Application/" + .metadata.name]
    | join(" ")' <<<"$apps") || return 1
  out="$s $a"
  out="${out# }"
  echo "${out% }"
}

# force_delete <kind/name>: strip the finalizers of one ApplicationSet or Application, delete it.
force_delete() {
  local res
  case "${1%%/*}" in
  ApplicationSet) res=applicationsets.argoproj.io ;;
  *) res=applications.argoproj.io ;;
  esac
  $KC patch "$res" "${1#*/}" -n "$GITOPS_NS" --type=merge -p '{"metadata":{"finalizers":null}}' >/dev/null 2>&1 || true
  $KC delete "$res" "${1#*/}" -n "$GITOPS_NS" --ignore-not-found --wait=false >/dev/null 2>&1 || true
}

cleanup_named() {
  local deadline wanted what last="" rest item
  local -a items=()
  APPS_JSON="$(json_list "${NAMED_APPS[@]}")"
  APPSETS_JSON="$(json_list ${NAMED_APPSETS[@]+"${NAMED_APPSETS[@]}"})"

  echo "=== Waiting until ${ROOT_APP} no longer renders: ${APP_NAMES} (timeout: ${ROOT_WAIT_SEC}s) ==="
  deadline=$((SECONDS + ROOT_WAIT_SEC))
  while :; do
    if wanted="$(root_wants 2>/dev/null)"; then
      if [[ -z "$wanted" ]]; then
        echo "  ${ROOT_APP} is gone or no longer renders them."
        break
      fi
      what="${ROOT_APP} still renders: ${wanted}"
    else
      what="cannot read Application ${ROOT_APP}"
    fi
    if [[ "$what" != "$last" ]]; then
      echo "  $what"
      last="$what"
    fi
    if ((SECONDS >= deadline)); then
      echo "WARNING: after ${ROOT_WAIT_SEC}s, ${what}; deleting anyway (its self-heal may recreate them)" >&2
      break
    fi
    sleep "$POLL_SEC"
  done

  echo "=== Deleting Applications: ${APP_NAMES} (cascade via finalizer) ==="
  for item in "${NAMED_APPS[@]}"; do
    $KC delete applications.argoproj.io "$item" -n "$GITOPS_NS" --ignore-not-found --wait=false ||
      echo "warning: deleting Application $item failed" >&2
  done

  echo "=== Waiting for them${APPSET_NAMES:+, ApplicationSets ${APPSET_NAMES} and the Applications they own} to go (timeout: ${TIMEOUT_SEC}s) ==="
  deadline=$((SECONDS + TIMEOUT_SEC))
  last=""
  while :; do
    if rest="$(left 2>/dev/null)"; then
      if [[ -z "$rest" ]]; then
        echo "  All removed."
        return 0
      fi
      what="left: ${rest}"
    else
      rest=""
      what="cannot list Applications or ApplicationSets in ${GITOPS_NS}"
    fi
    if [[ "$what" != "$last" ]]; then
      echo "  $what"
      last="$what"
    fi
    if ((SECONDS >= deadline)); then
      break
    fi
    sleep "$POLL_SEC"
  done

  # Unreadable lists: only the names given are known.
  if [[ -z "$rest" ]]; then
    for item in ${NAMED_APPSETS[@]+"${NAMED_APPSETS[@]}"}; do rest+="${rest:+ }ApplicationSet/${item}"; done
    for item in "${NAMED_APPS[@]}"; do rest+="${rest:+ }Application/${item}"; done
  fi
  read -r -a items <<<"$rest"
  # ApplicationSets first, so none regenerates an Application whose finalizer is gone.
  for item in "${items[@]}"; do
    if [[ "$item" == ApplicationSet/* ]]; then force_delete "$item"; fi
  done
  for item in "${items[@]}"; do
    if [[ "$item" == Application/* ]]; then force_delete "$item"; fi
  done
  echo "WARNING: not gone within ${TIMEOUT_SEC}s: removed the finalizers of and deleted ${rest}. What they deployed may be left on the clusters." >&2
  return 0
}

if ((${#NAMED_APPS[@]})); then
  cleanup_named
  echo "=== Cleanup of ${APP_NAMES} complete ==="
  exit 0
fi

echo "=== Deleting hub-gitops-root Application (cascade via finalizer) ==="
$KC delete application.argoproj.io "hub-gitops-root" -n "$GITOPS_NS" --wait=false 2>/dev/null || true

echo "=== Waiting for Applications and ApplicationSets to be cleaned up (timeout: ${TIMEOUT_SEC}s) ==="
DEADLINE=$((SECONDS + TIMEOUT_SEC))
while ((SECONDS < DEADLINE)); do
  APPS=$($KC get applications.argoproj.io -n "$GITOPS_NS" -o jsonpath='{.items[*].metadata.name}' 2>/dev/null | wc -w)
  APPSETS=$($KC get applicationsets.argoproj.io -n "$GITOPS_NS" -o jsonpath='{.items[*].metadata.name}' 2>/dev/null | wc -w)
  TOTAL=$((APPS + APPSETS))
  if [ "$TOTAL" -eq 0 ]; then
    echo "  All Applications and ApplicationSets removed."
    exit 0
  fi
  echo "  $TOTAL resources remaining (apps=$APPS, appsets=$APPSETS). Waiting ${POLL_SEC}s..."
  sleep "$POLL_SEC"
done

echo "WARNING: Timeout. Force-clearing finalizers on remaining resources..."
for app in $($KC get applications.argoproj.io -n "$GITOPS_NS" -o jsonpath='{.items[*].metadata.name}' 2>/dev/null); do
  $KC patch application.argoproj.io "$app" -n "$GITOPS_NS" --type=json \
    -p '[{"op":"remove","path":"/metadata/finalizers"}]' 2>/dev/null || true
  $KC delete application.argoproj.io "$app" -n "$GITOPS_NS" --wait=false 2>/dev/null || true
done
for appset in $($KC get applicationsets.argoproj.io -n "$GITOPS_NS" -o jsonpath='{.items[*].metadata.name}' 2>/dev/null); do
  $KC delete applicationset.argoproj.io "$appset" -n "$GITOPS_NS" --wait=false 2>/dev/null || true
done
echo "=== ArgoCD Application cleanup complete ==="
