# Platform and mesh (Terraform)

Installs Argo CD on the hub, registers the other clusters with it, and starts the Argo CD
app-of-apps that deploys the whole mesh (Sail operator, Istio, shared CA, secrets, gateways).

| `platform` | Hub gets | Clusters join through | Members get |
| --- | --- | --- | --- |
| `kubernetes` (default) | upstream Argo CD (`argo-cd` Helm chart) | an Argo CD cluster Secret each, with a ServiceAccount token | the upstream Sail operator (Helm) |
| `openshift` (optional, untested) | ACM and OpenShift GitOps (OLM) | ACM ManagedClusters, plus the Argo CD cluster Secrets | OSSM 3 (OLM) |

Two ways to find clusters:

| `cluster_provider` | Clusters come from | Hub |
| --- | --- | --- |
| `kubeconfig` (default) | `kubeconfig_path` + context names | `hub_cluster_context` |
| `rosa` (implies `platform = "openshift"`) | `terraform/rosa-hcp` state | the first cluster |

`platform` defaults to `kubernetes`, or to `openshift` with `cluster_provider = "rosa"`.
Upgrading a deployment from before `platform` existed (OpenShift only, `cluster_provider`
defaulting to `rosa`): set `cluster_provider = "rosa"`, or `platform = "openshift"` for OpenShift
clusters from a kubeconfig, before the first plan. In kubeconfig mode every plan reads the hub's
API groups and fails before any change when they disagree with `platform` (an OpenShift hub serves
`security.openshift.io/v1`); a destroy plan, or a hub it cannot read, only gives a warning.

The hub runs Argo CD (and ACM on OpenShift) and is never a mesh member. Spoke context names become
the Argo CD cluster names (and ManagedCluster names on OpenShift), so they must be DNS-1123 labels:
short, lowercase, no `:` or `/`. Rename a context that is not, for example an EKS ARN:
`kubectl config rename-context <arn> mesh-a` (or `aws eks update-kubeconfig --alias mesh-a`).

## Run

```bash
cp terraform.tfvars.example terraform.tfvars   # platform, repo URL/branch, cluster_provider, contexts
./scripts/001-openapi-preflight.sh --contexts <hub-ctx>   # existing OpenShift hubs only
terraform init
terraform plan -out=platform.tfplan
./scripts/002-plan-leftover-check.sh platform.tfplan   # objects already on the hub
terraform apply platform.tfplan
```

`002-plan-leftover-check.sh` lists every object the plan creates that exists on the hub already,
with the `terraform import` command that adopts it. Such objects are left when a Terraform state
is lost (a rebuild from scratch), or were made by hand, and an apply would stop partway on
`Cannot create resource that already exists`. Import each one, or delete the ones nothing needs,
then plan again. The check is read-only and exits 0 when there is none.

Then watch the rollout until every Application is Synced/Healthy (about 15–20 minutes):
`kubectl --context <hub-ctx> get applications.argoproj.io -n argocd` (`terraform output
gitops_namespace` names the namespace: `openshift-gitops` on OpenShift). A kind lab on one machine:
[docs/runbooks/kind-lab](../../docs/runbooks/kind-lab/README.md).

What the apply needs to reach:

- Every cluster's API server from this machine (the kubeconfig's URLs), and every member's API
  server from the hub's pods and from every other member: the URL goes into the member's Argo CD
  cluster Secret and from there into the External Secrets stores and the Istio remote secrets,
  which the other members' istiod use. When the kubeconfig's URL works only from this machine
  (kind writes `https://127.0.0.1:<port>`), set a URL that works from all of them in
  `cluster_api_url_overrides`. The apply fails at its end when Argo CD cannot reach a member (see
  below), and the wiring gate on each member names a member whose remote secret it lacks or whose
  cluster its istiod cannot sync.
- The Argo CD chart repo (`argocd_chart_repository`) from this machine, and the git repo
  (`gitops_app_repo_url`) plus the operator chart repos from the hub (Argo CD pulls them): a
  mirror goes in through `gitops_app_overrides` (`terraform.tfvars.example`).

On `kubernetes` each member gets a ServiceAccount bound to `cluster-admin`
(`gitops_managed_service_account_name` in `spoke_service_account_namespace`,
`istio-scale-tests-access` by default) whose token authenticates Argo CD, the External Secrets
pushes and the Istio remote secrets to it. The hub's Argo CD Secret holds that token: treat the
hub as the mesh's trust root. The apply creates the namespace when it is missing, labelled
`istio-scale-tests/created-by`, and destroy deletes it only with that label. It is not
`kube-system`: ServiceAccounts there share the API server's `workload-high` priority level
(FlowSchema `kube-system-service-accounts`) with the controllers the suites measure, while this
token falls under `service-accounts` (`workload-low`). Setting it to `kube-system` keeps the old
layout.

A deployment from before this default has the ServiceAccount in `kube-system`, and the next apply
moves it. Per member it creates the new ServiceAccount, its token and the binding, points the hub's
cluster Secret at the new token, then deletes the old ServiceAccount and token Secret (only those
labelled `app.kubernetes.io/part-of=istio-scale-tests`; `kube-system` itself stays) and prints
which it removed, found missing or left. Argo CD switches at once. The other members' istiod keep the old token until External Secrets pushes the
new remote secret, up to about 10 minutes (the ExternalSecret and the PushSecret each refresh every
5): until then they log `watch error in cluster <member>: Unauthorized` and keep that member's last
endpoints, then reconnect without a restart (66 s and 4.5 minutes on the kind lab). Run no suite
until every istiod replica of every other member has logged
`stopping previous cluster <member> after new cluster synced` for each moved member
(`kubectl -n istio-system logs -l app=istiod --prefix --tail=-1 | grep 'stopping previous cluster'`;
`Update cluster` marks only the start of the switch): the wiring gate cannot see this, because
istiod's sync metric changes only when it reconnects.

At the end, the apply waits until Argo CD has rendered and compared everything it deploys, and
fails after `argocd_app_status_timeout_sec` (default 900; 0 disables), naming what is missing and
the fix. Every Application or ApplicationSet that an Application lists in its resources must exist
(the app-of-apps lists its child Applications, each child the ApplicationSet it deploys); each of
the repo's ApplicationSets that selects clusters must own an Application per mesh member (the
hub-side presets' Applications target the hub, so they are counted, not matched; the failure
gives `<k> of <N>` and the ApplicationSet's `ErrorOccurred` message); every mesh member must be the
destination of an Application; and every Application must have a sync and health status. The
ApplicationSets generate the member Applications minutes after the apply's own (on the kind lab
3 of 33 existed after 11 s). For a spoke with no Applications, check its Argo CD
cluster Secret (`kubectl -n argocd get secret -l argocd.argoproj.io/secret-type=cluster
--show-labels`: mesh members carry `istio-mesh-member=true`; on OpenShift also its ACM
PlacementDecision). Argo CD's errors are printed once each when first seen, so you can stop the
apply and fix them; they fail the check if they last until the deadline. When Argo CD cannot
load state from a member (its Applications are sync `Unknown` with `Failed to load live state` or
`failed to get cluster info`): the registered URL is unreachable from the hub
(`cluster_api_url_overrides`), or `Unauthorized` or `Forbidden` says the token is not accepted (see
[Rotating a member's token](#rotating-a-members-token)). Any other `ComparisonError` (a chart that
fails to render, a repository Argo CD cannot read) means that Application never deploys. A status
from before the apply never counts: the check asks Argo CD to refresh every Application once
(`argocd.argoproj.io/refresh=normal`) and waits until each has been compared again, naming any
that never is. It runs again on every apply that changes a member's registration or, on
`kubernetes`, the Argo CD release.

On OpenShift a second step guards Argo CD's controller sharding: once every cluster Secret exists,
the apply waits for the GitOps operator's own dynamic-scaling restart of the application controller
to settle, then restarts the controller pods once. A controller that starts while the Secrets
change can leave a cluster without a shard, and that cluster's Applications never get a status;
the fix by hand is the same restart:
`oc -n openshift-gitops delete pod -l app.kubernetes.io/name=openshift-gitops-application-controller`.
On `kubernetes` the controller runs a fixed number of replicas (the computed count, or
`argocd_helm_values`' `controller.replicas`), so nothing rescales it mid-apply, and the apply pins
each spoke to one: the `shard` key of the spoke's cluster Secret is its index in name order plus 1,
mod the replica count. The spokes spread round-robin, and the hub's own `in-cluster`, which has no
Secret, stays on shard 0, where round-robin (`kubernetesShardingAlgorithm` in
`charts/argocd-config`) puts it. Unpinned, Argo CD re-indexes its clusters whenever one is added or
removed, but a replica drops a cluster's cache only when that cluster's own Secret changes, so while
the Secrets arrive one at a time replicas keep caching clusters they no longer own. A pinned spoke
changes owner only when the apply updates its Secret, and the replica that owned it then drops its
cache. Adding or removing a spoke re-pins the spokes after it in name order, and a new replica count
re-pins most of them (the apply changes the replica count first: until it re-pins, a spoke whose pin
is at or above the new count sits on shard 0, and the controller logs
`is greater than the number of available shard`). The pins follow from the names alone, so anyone
can work out a spoke's owner: adding a spoke to `spoke_cluster_contexts` moves every spoke that
sorts after it one shard on (removing one, one back), a name that sorts last (zero-padded `mesh-021`
after `mesh-020`) moves none unless the replica count changes with it, and `mesh_member_count`
moves none (it labels spokes, it adds none). Each moved spoke costs one cache rebuild: its new owner
lists and watches everything Argo CD tracks on that member from scratch while the old one drops its
copy, and its Applications are not compared until the new cache has synced. So change membership
between test runs, not during one. With `gitops_install_operator = false` the apply
pins nothing (it does not know the existing Argo CD's replica count; restart its controller pods
after adding spokes, or pin the shards yourself) and drops a pin it wrote before; a `shard` key
someone else set stays, and the apply warns about it. The controller logs say
which replica owns which cluster (every replica logs the whole map):
`kubectl -n argocd logs argocd-application-controller-0 | grep -e 'assigned to shard' -e 'changed shard'`.

## Existing clusters

| Already installed on the hub | Set |
| --- | --- |
| Argo CD (`kubernetes`), in `gitops_namespace` | `gitops_install_operator = false` |
| cert-manager | `gitops_app_overrides = { "hub-cert-manager-operator" = { enabled = false } }` |
| ACM (`openshift`) | `acm_install_operator = false`, `acm_local_cluster_name = "local-cluster"` |
| OpenShift GitOps (`openshift`) | `gitops_install_operator = false` |
| OpenShift GitOps from an apply of this repo before 2026-10-26 | `gitops_operator_namespace = "openshift-operators"` |

An existing Argo CD must run with the release name `argocd` (its controllers' ServiceAccounts are
`argocd-application-controller` and `argocd-applicationset-controller`, which the charts' RBAC
expects) and carry the settings `platform_gitops.tf` gives the chart (`argocd_upstream_values`):
the Sail health checks, the resource exclusions, round-robin sharding and git submodules off. With
`gitops_install_operator = false` nothing applies `argocd_helm_values`, so the plan warns when it
is set.

On OpenShift, Terraform subscribes the GitOps operator in `gitops_operator_namespace`
(`openshift-gitops-operator`, with its own OperatorGroup, as Red Hat installs it). In a
namespace shared with other operators, a single Subscription there with Manual approval makes the
GitOps InstallPlan Manual too, and the install waits for someone to approve it. The default was
`openshift-operators` until 2026-10-26: a deployment applied before then keeps its operator there
with `gitops_operator_namespace = "openshift-operators"`, and in kubeconfig mode its plan fails
until that is set. While the apply waits for an operator (GitOps or ACM), it prints an InstallPlan
that needs approval, with the command that approves it, and any catalog or resolution error, as
soon as it sees one. An operator that is installed already does not wait for its upgrade's
approval: the apply goes on with the installed version.

If the spokes are already ACM-managed (OpenShift), import their namespaces once before the first
apply: `terraform import 'kubernetes_manifest.spoke_namespace["<ctx>"]' "apiVersion=v1,kind=Namespace,name=<ctx>"`.

## Per-environment values

The chart defaults are sized for the 20-cluster campaign: about 12.2 CPU / 49 GiB of requests per
member (istiod's 3 replicas of 4 CPU / 16 GiB) and, on the hub, Argo CD's 3 CPU / 6 GiB plus 2 CPU /
4 GiB per controller replica, ceil((spokes + 1) / `argocd_clusters_per_shard`): 5 CPU / 10 GiB
for 2 members, 17 CPU / 34 GiB for 20. These are requests, what the scheduler sets aside: pods
that request less CPU than they use still load a small node. Pod slots count too, 110 per node by
default on Kubernetes and 250 on OpenShift: on an OpenShift hub ACM 2.17 starts about 81 pods, and
OpenShift GitOps and the hub charts about 20. A kubeconfig-mode plan warns when no MultiClusterHub
exists yet and fewer than 100 slots are free; a pod left without one stays Pending with
`Too many pods`, and the reshard step names it. Override the sizing per environment without
forking:

- `gitops_app_overrides`: per child app `enabled` and `values` (for example a smaller istiod, a
  MetalLB pool for the gateways, or a chart mirror). See `terraform.tfvars.example`.
- `argocd_helm_values` (`kubernetes`): values for the `argo-cd` chart, merged over the repo's
  tuning (`charts/argocd-config/values.yaml`); for example smaller requests on a small hub.
  `argocd_config_values` is the same for the OpenShift GitOps ArgoCD CR. Keep the controller
  limit near 6Gi on a busy hub.
- `mesh_member_count`: how many spokes join the mesh, in sorted order (0 = all). The wiring gate
  on each member gets their names (`expectedClusters`, the spoke keys: each member's Argo CD cluster
  name, Istio cluster ID and remote-secret suffix), checks every other member by name and names a
  removed member's leftover remote secret ([README](../../README.md#grow-the-mesh)). Change it
  between test runs, not during one.
- Large fleets: `argocd_clusters_per_shard` (`argocd_max_shards` only on OpenShift; on
  `kubernetes` the replica count is the computed one unless `argocd_helm_values` sets
  `controller.replicas`, and the shard pins follow it).
- ROSA: the ingress gateway Service gets an AWS NLB (`rosa_ingress_nlb`, default true). Behind a
  Classic LB it aborted HTTP requests (each arrived followed by a FIN); the east-west gateway
  (mTLS passthrough) stays on a Classic LB. This default is merged under `gitops_app_overrides`,
  so an override of `spoke-ingress-gateway-appset` adds to it. A Service created as a CLB does not
  change type in place: delete it once and Argo CD recreates it as an NLB. On EKS set the same
  annotation yourself (`service.beta.kubernetes.io/aws-load-balancer-type: nlb`) through
  `gitops_app_overrides`.

The child apps sync from `gitops_app_repo_url` at `gitops_app_repo_revision`, so a fork or branch
deploys from itself. Edited charts roll out on the next apply.

## OpenShift add-ons: ACM Observability and Kiali

Two toggles, both off by default and both for `platform = "openshift"` only (the plan refuses
them on `kubernetes`, and with them off nothing changes on the clusters or in the app-of-apps
values).
Together they give one Kiali on the ACM hub that shows every mesh member: namespaces, workloads,
services, Istio config validation, and a traffic graph and metrics for the namespaces you list.

| Toggle | Installs | Where | By |
| --- | --- | --- | --- |
| `acm_observability` | The `MultiClusterObservability` (`observability`), ACM's custom metrics allowlist, the namespace `open-cluster-management-observability`, a copy of the hub's pull secret and the Secret `thanos-object-storage` ([charts/acm-observability](../../charts/acm-observability/README.md)). ACM then runs Thanos, Grafana and the Observatorium API on the hub and a metrics collector on every managed cluster, the hub included | hub | Terraform |
| `acm_observability` | Per mesh member and per namespace in `istio_metrics_namespaces`: an Envoy PodMonitor and an allowlist; in `istio-system` also the istiod ServiceMonitor and `openshift-monitoring/cluster-monitoring-config` (user workload monitoring) ([charts/spoke-mesh-metrics](../../charts/spoke-mesh-metrics/README.md)). Applications `<member>-mesh-metrics-<namespace>` | members | Argo CD (`spoke-mesh-metrics-appset`, wave 30) |
| `kiali_multicluster` | The Kiali operator (OLM `kiali-ossm`, namespace `kiali-operator`) and a Kiali CR in `istio-system` that creates only Kiali's read-only ServiceAccount, its roles and the OAuthClient, plus that ServiceAccount's token Secret ([charts/kiali](../../charts/kiali/README.md)). Applications `<member>-kiali` | members | Argo CD (`spoke-kiali-appset`, wave 31) |
| `kiali_multicluster` | The Kiali operator and the Kiali server in `istio-system` (external deployment model: it reads the members remotely and ignores the hub's own cluster) | hub | Argo CD (`hub-kiali`, wave 32) |
| `kiali_multicluster` | One remote cluster secret per member, `istio-system/kiali-remote-cluster-secret-<member>`, which External Secrets builds from the member's token ([charts/hub-kiali-remote-secret](../../charts/hub-kiali-remote-secret/README.md)) | hub | Argo CD (`hub-kiali-remote-secret-appset`, wave 33) |
| `kiali_multicluster` | The Kiali CR's health check in the ArgoCD CR (`charts/argocd-config`) | hub | Terraform |

Kiali needs the app-of-apps (`enable_gitops`, `gitops_app_repo_url`). It works without
`acm_observability`, but then its graph and metrics stay empty, and the plan warns.

Upgrading an existing platform state to the commit that added the add-ons, with both off, still
plans two in-place updates, `helm_release.argocd_config` and `helm_release.mesh_wiring_verify_appset`:
their charts gained the add-ons' options, so their `chartChecksum` changed. They render the same
manifests, so the two helm upgrades change nothing on the hub.

### Before you turn them on

- Object storage for Thanos. `cluster_provider = "rosa"`: apply `terraform/rosa-hcp` with
  `acm_observability_bucket = true` first; it creates an S3 bucket and an IAM role that the Thanos
  ServiceAccounts assume through the hub's OIDC provider (STS), and this root reads both from its
  state (`terraform/rosa-hcp/README.md`). `cluster_provider = "kubeconfig"`: pass the whole
  `thanos.yaml`, in the format of the ACM Observability docs, in `acm_observability_object_storage`
  (`export TF_VAR_acm_observability_object_storage="$(cat thanos.yaml)"`). Without either the plan
  stops at the `thanos-object-storage` Secret and says which.
- Every member reaches the hub's `observatorium-api` Route (`*.<hub apps domain>`): the collectors
  push there directly (the ACM docs support no proxy in between).
- Hub capacity: the add-ons request about 2.9 CPU and 12.6 GiB more on the hub (ACM's default
  Observability size 2.7 CPU / 11.7 GiB, the hub's own collectors, the Kiali server 100m / 256Mi
  and its operator). Each member gets the user workload monitoring stack (two Prometheus
  replicas), the collectors (about 22m / 250Mi) and one Kiali operator pod, no Kiali server.

```hcl
acm_observability = {
  enabled = true
  # Add your own test namespaces; istio-system stays.
  istio_metrics_namespaces = ["istio-system", "mesh-verify", "mesh-verify-gwapi", "mesh-verify-gwapi-shared", "<my-test-ns>"]
}
kiali_multicluster = { enabled = true }
```

### Values

- `acm_observability.interval_sec` (60): seconds between the collectors' pushes to the hub,
  15 to 3600. It is also Kiali's `thanos_proxy.scrape_interval`, which must match or Kiali's
  charts stay empty, so set it only here. ACM's default is 300; 60 makes Kiali's view fresher and
  sends five times as many samples into the hub.
- `acm_observability.retention` (`14d`): how long Thanos keeps raw, 5m and 1h data, and Kiali's
  `thanos_proxy.retention_period`. Kiali's docs ask for at least 10 days, for the downsampled data.
- `acm_observability.storage_class` (empty: the default StorageClass, `gp3-csi` on ROSA). The
  Thanos volume sizes (about 116 GiB in all) take effect at the first apply only: change them with
  `mco.storageSizes` in `acm_observability_values` before it.
- `acm_observability.istio_metrics_namespaces`: the member namespaces whose Envoy metrics are
  scraped and sent; default `istio-system` (istiod and the gateways) and the three mesh-verify
  namespaces. One Argo CD Application per member and namespace, and Argo CD creates a namespace
  that does not exist yet, so an on-demand namespace such as `mesh-verify` can be listed before its
  check runs. It must hold `istio-system`, no namespace twice, and never
  `mesh-verify-gwapi-remote`: Argo CD would create that on every member, and the Gateway API
  check needs a member without it. The scale suites' namespaces are not in it: add a test namespace
  of your own here, knowing that each one adds series on the members and the hub (ACM's default
  size is rated for fewer than 200k active series).
- `acm_observability.enable_user_workload_monitoring` (true): Argo CD creates
  `openshift-monitoring/cluster-monitoring-config` on each member with only
  `enableUserWorkload: true`. Set false where a member has that ConfigMap already, and add the line
  to it yourself.
- `acm_observability_values`: extra values for `charts/acm-observability`, merged over
  Terraform's, for example `mco.advanced` with per-component resources.
- `kiali_multicluster.view_only` (true): Kiali's UI shows the mesh but makes no changes (the
  server's `view_only_mode`). The members' ServiceAccount has only the read-only `kiali-viewer`
  role either way; with `false`, a change made in the UI goes through with the logged-in user's own
  OpenShift permissions on that cluster.
- The hub's ACM cluster (`acm_local_cluster_name`) stays enrolled in Observability, which gives
  ACM's Grafana the hub's own load during a run.

### What an apply does

1. Terraform adds the Kiali health check to the ArgoCD CR and the add-ons' child apps to the
   app-of-apps, and creates the observability namespace and its two Secrets (after the
   MultiClusterHub).
2. Argo CD syncs the child apps in wave order. On each member user workload monitoring comes up
   and the monitors and allowlists appear in each listed namespace; the Kiali operator installs,
   its CR creates the ServiceAccount, and the token Secret follows once the CR is healthy. On the
   hub the Kiali server starts, External Secrets copies each member's token into a remote cluster
   secret, and `hub-kiali`'s PostSync hook waits for all of them (30 minutes at most) and annotates
   the Kiali CR so the operator mounts them.
3. The apply's Argo CD status check runs, then Terraform installs the MultiClusterObservability:
   ACM's user workload collector on a member starts only once that member's user-workload
   Prometheus exists. ACM then takes a few minutes to start Thanos on the hub and the collectors
   on every cluster.

### Check it

```bash
oc --context <hub-ctx> get multiclusterobservability observability -o jsonpath='{.status.conditions}'   # Ready
oc --context <hub-ctx> -n open-cluster-management-observability get pods
oc --context <hub-ctx> get managedclusteraddons -A | grep observability   # Available on every cluster
oc --context <hub-ctx> -n openshift-gitops get applications.argoproj.io | grep -e mesh-metrics -e kiali
oc --context <mesh-a-ctx> -n openshift-user-workload-monitoring get pods
oc --context <hub-ctx> -n istio-system get kialis.kiali.io kiali -o jsonpath='{.status.conditions}'   # Successful
oc --context <hub-ctx> -n istio-system get secrets -l kiali.io/multiCluster=true   # one per member
# The members' Istio metrics in Thanos: one row per member.
oc --context <hub-ctx> -n open-cluster-management-observability port-forward svc/observability-thanos-query-frontend 9090 &
curl -s http://localhost:9090/api/v1/query --data-urlencode 'query=count by (cluster) (istio_build)'
```

On ROSA in STS mode, the Thanos pods carry the role (`AWS_ROLE_ARN` in
`oc --context <hub-ctx> -n open-cluster-management-observability get pod observability-thanos-compact-0 -o yaml`)
and the bucket fills with blocks about two hours after the start. If the compact log shows S3
`AccessDenied`, switch to a static key ([charts/acm-observability](../../charts/acm-observability/README.md#object-storage-sts-or-static-keys)).

### Log in

`terraform output kiali_url` gives the hub's Kiali route (null while `kiali_multicluster` is
off). Log in there with an OpenShift account of the hub, then once per member through
"Login to <member>" in the profile menu: four logins with three members. OpenShift OAuth has no
single sign-on across clusters; Kiali's single login needs Kiali 2.30 or later, and OSSM 3.4 ships
2.27. The route's host comes from the hub's ingress config at plan time and is kept only in the
state and the root Application.

### Turn them off

Set `enabled = false` and apply. Turning `kiali_multicluster` off first updates the app-of-apps,
which then stops rendering the three Kiali child apps; the root syncs with prune off, so the apply
next deletes them itself (`kiali_app_cleanup`) and waits until they are gone. Their PreDelete hooks
delete each Kiali CR (the operator removes its OAuthClient, roles and ServiceAccount) and then the
operator; a last step (`kiali_cr_cleanup`) deletes any Kiali CR, Subscription or CSV left on each
cluster, and the Kiali health check leaves the ArgoCD CR. Left behind: the hub's `istio-system`
namespace and the CRD `kialis.kiali.io`.

The cleanup resources are `create_before_destroy`: that is what puts the app-of-apps update first.
Without it Terraform would destroy them first (an updated resource waits for the destroy of what it
depends on), the root's self-heal would recreate the apps the cleanup deletes, and they would stay
behind, deployed, once the update lands. After the apply, this should list nothing for the add-on
you turned off:

```bash
oc --context <hub-ctx> -n openshift-gitops get applications.argoproj.io,applicationsets.argoproj.io | grep -e kiali -e mesh-metrics
```

Turning `acm_observability` off works the same way for the member metrics Applications (the
monitors, the allowlists and `cluster-monitoring-config`, which stops user workload monitoring;
`mesh_metrics_member_cleanup` deletes what is left of them on each member), and it uninstalls the
MultiClusterObservability. The apply then waits, up to 15 minutes, until ACM has removed the MCO
and every cluster's ObservabilityAddon, and only then deletes the Secrets and the namespace (the
Thanos volumes go with it). If the wait fails it names what is left, with the commands to inspect
it, and the apply stops before the namespace goes. Left behind: the namespaces Argo CD created for
listed namespaces that did not exist (delete them by hand when nothing else uses them) and the
bucket's data, until `terraform/rosa-hcp` drops the bucket.

### Caveats

- Kiali's graph has gaps under the mesh's tuning baseline (client-side request metrics off), for
  example edges to unselected namespaces and egress destinations:
  [charts/kiali/README.md](../../charts/kiali/README.md).
- Observer effect: the user workload Prometheus and the collectors add load on the members. Keep
  the add-on off while a suite measures; the suites' platform record does not show it yet.
- Kiali version drift: `kiali-ossm` has no channel per minor version. `startingCSV` pins the first
  install only, and with automatic approval OLM moves to a newer Kiali when its `stable` channel
  gets one, which may then be ahead of OSSM's (BACKLOG.md, section 10: Manual approval).
- The hub's pull secret and `thanos.yaml` (with a static key, the key too) are in this root's
  state.
- The hub's in-cluster Thanos query-frontend (port 9090), which Kiali queries, has no
  authentication and serves every cluster's metrics to anything that can reach the service. The
  mutual-TLS Observatorium path is a follow-up (BACKLOG.md, section 10).

## Rotating a member's token

On `kubernetes` the token in a member's Argo CD cluster Secret comes from the Secret
`argocd-gitops-token` (`<gitops_managed_service_account_name>-token`) in
`spoke_service_account_namespace` on the member. It never expires. Its claims are the
ServiceAccount's name and UID and the Secret's name, so with an RSA signing key (kind's and
kubeadm's) a recreated Secret brings back the same token. Recovering a deleted token Secret is
therefore a re-registration; rotating the token (revoking the old one) deletes the ServiceAccount
too:

```bash
# Rotate only: revoke the current token. Skip both lines to recover a deleted token Secret.
kubectl --context <ctx> -n istio-scale-tests-access delete secret argocd-gitops-token
kubectl --context <ctx> -n istio-scale-tests-access delete serviceaccount argocd-gitops
# Register the member again: ServiceAccount, token and binding, then the hub's cluster Secret.
terraform plan -replace='terraform_data.create_argocd_cluster_secret["<ctx>"]' -out=rotate.tfplan
terraform apply rotate.tfplan
```

The replace updates the hub's cluster Secret in place (deleting it would delete the member's
Applications), and the apply's status check runs again. While the member has no working token:

- Argo CD answers from its cache. Only an Application whose comparison needs a fresh call goes sync
  `Unknown` with `... Unauthorized`; the rest can read Synced/Healthy for minutes.
- Every other member's istiod logs `watch error in cluster <ctx>: Unauthorized` as its watches
  restart (each within 5 to 10 minutes) and keeps that member's last endpoints. The wiring gates
  stay Ready: istiod's sync metric changes only when it reconnects.
- The hub's PushSecrets go `Errored` with `could not write remote ref ... to target secretstore
  <ctx>-spoke-istio-system: Unauthorized` (`kubectl -n external-secrets-operator get
  pushsecrets`): nothing new reaches the member.

After the apply a recovered token, being the same, works everywhere at once (one that differs,
under another signing key type, goes the way of a rotated one). A rotated one works
for Argo CD at once and reaches the other members through External Secrets: the
`kubeconfig-<ctx>` ExternalSecret and the `push-remote-secret-<ctx>` PushSecret each refresh every
5 minutes, so within about 10 (17 seconds to 4.5 minutes on the kind lab). Each istiod replica
then reconnects without a restart: it logs `Update cluster` when it starts the new connection and
`stopping previous cluster <ctx> after new cluster synced` once that one has synced
(`kubectl -n istio-system logs -l app=istiod --prefix --tail=-1 | grep 'stopping previous cluster'`).
Run no suite before every replica of every other member has logged the second. On the kind lab
(Istio 1.30.5) one istiod went on logging `watch error in
cluster <ctx>: failed to list *v1.ConfigMap: Unauthorized` about once a minute for over 30 minutes
after that, from a watch the previous connection left behind, while `istioctl remote-clusters` read
`synced` and the member's endpoints stayed current. Restarting that member's istiod pods leaves
only the current connection; do it before a measured run, one pod at a time (`kubectl -n
istio-system delete pod <istiod-pod>`, then wait for its replacement to be Ready): `kubectl rollout
restart` starts a full set of new replicas first (maxSurge 100%), which needs room for as many more
istiod pods. On `openshift` the ACM ManagedServiceAccount issues and rotates the token.

## Tear down

`terraform destroy` deletes the Argo CD apps first, then uninstalls what Terraform installed. On
`kubernetes` it also deletes each spoke's Argo CD cluster Secret and its ServiceAccount, so no
cluster-admin token is left behind, and the `spoke_service_account_namespace` namespace when the
apply created it (never `kube-system` or a namespace without its label). For ROSA, then follow
`terraform/rosa-hcp/README.md`.

With the OpenShift add-ons on, destroy first deletes the Kiali and member metrics Applications
with the rest (their PreDelete hooks remove the Kiali CRs and operators; the cascade then waits up
to 20 minutes instead of 10), then deletes any Kiali CR, Subscription or CSV and anything labelled
by `charts/spoke-mesh-metrics` left on each cluster. In parallel it uninstalls the MultiClusterObservability
and waits, up to 15 minutes, until ACM has removed it and every cluster's ObservabilityAddon,
before the observability namespace, the MultiClusterHub and the spokes go; when the wait fails the
destroy stops there and names what is left. The `terraform/rosa-hcp` destroy then deletes the
bucket with its data, the IAM role and policy (and the static key's user), and its teardown audit
checks for them by name.

On an existing OpenShift hub (`acm_install_operator = false`) destroy keeps the MultiClusterHub and
the KlusterletConfig, but still deletes:

- the spoke ManagedClusters, unless `acm_keep_managed_clusters_on_destroy = true`;
- the spoke namespaces you imported. To keep them, first run
  `terraform state rm 'kubernetes_manifest.spoke_namespace'`;
- the OSSM operator on every spoke.

On OpenShift destroy leaves the Argo CD cluster Secrets, which hold spoke credentials. Delete them
afterwards: `oc -n openshift-gitops delete secret <spoke>-argocd-gitops-cluster-secret` per spoke,
or `oc -n openshift-gitops delete secret -l argocd.argoproj.io/secret-type=cluster` if that Argo CD
manages no other clusters.
