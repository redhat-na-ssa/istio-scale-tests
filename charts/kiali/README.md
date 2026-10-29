# kiali

OpenShift add-on, off by default (`terraform/platform` `kiali_multicluster`): one Kiali for the
whole mesh, running on the ACM hub in Red Hat's external deployment model. The hub has no Istio;
Kiali reads each mesh member through a remote cluster secret. Setup, verification and teardown:
[terraform/platform/README.md](../../terraform/platform/README.md#openshift-add-ons-acm-observability-and-kiali).

| `mode` | Runs on | Argo CD Application | Installs |
| --- | --- | --- | --- |
| `hub` | ACM hub | `hub-kiali` (`charts/gitops-hub-apps`, wave 32) | The Kiali operator (OLM) in `kiali-operator`; the Kiali CR `kiali` in `istio-system` (the server: `clustering.ignore_home_cluster: true`, remote secrets autodetected); a PostSync reconcile hook |
| `remote` | each mesh member | `<member>-kiali` (ApplicationSet `spoke-kiali`, `values-kiali.yaml`, wave 31) | The same operator; a Kiali CR with `deployment.remote_cluster_resources_only: true`, which creates only the ServiceAccount `kiali-service-account`, its read-only `kiali-viewer` role and the OAuthClient `kiali-istio-system`; the Secret `kiali-service-account`, a long-lived token for that ServiceAccount |

No Kiali server runs on the members. On the hub, `charts/hub-kiali-remote-secret` turns each
member's token into `istio-system/kiali-remote-cluster-secret-<member>`. Metrics come from ACM
Observability's Thanos (`charts/acm-observability`, `acm_observability`); without it Kiali still
lists clusters, namespaces, workloads and Istio config, but the graph and the metrics stay empty.

`kialiNamespace` is `istio-system` on every cluster: the OAuthClient takes its name from it
(`kiali-istio-system`), and on a member the ServiceAccount then sits next to istiod.

## Values

| Key | Default | Purpose |
| --- | --- | --- |
| `mode` | `hub` | `hub` or `remote`; anything else fails the render |
| `clusterName` | `""` | hub: `kubernetes_config.cluster_name`, the ACM local cluster name (Terraform). remote: the member's cluster name (ApplicationSet), required |
| `hubRedirectBase` | `""` | remote, required: `https://kiali-istio-system.<hub apps domain>/api/auth/callback` (Terraform reads the domain from the hub at apply time). The member's redirect URI is `<hubRedirectBase>/<clusterName>` |
| `remoteClusters` | `[]` | hub: the members whose remote secrets the PostSync hook waits for (Terraform). Empty: no hook |
| `viewOnly` | `true` | `deployment.view_only_mode` of every CR |
| `prometheus.url` | the in-cluster Thanos query-frontend of ACM Observability | hub: where Kiali queries metrics (`auth.type: none`) |
| `prometheus.scrapeInterval`, `.retentionPeriod` | `60s`, `14d` | hub: `thanos_proxy`. Must equal the MCO's `observabilityAddonSpec.interval` and retention, or Kiali's charts stay empty; Terraform sets both from `acm_observability` |
| `server.resources` | 100m / 256Mi, limit 2Gi | hub: the Kiali server pod |
| `server.discoverySelectors` | istiod's (`istio-discovery=enabled`, `istio-system`) | hub: `deployment.discovery_selectors.default`, the namespaces Kiali watches on every member |
| `subscription.*` | `kiali-ossm`, channel `stable`, `startingCSV: kiali-operator.v2.27.5`, `Automatic` | Version pin (CONTRIBUTING.md): the Kiali that OSSM 3.4 ships |
| `reconcileHook.timeoutSeconds` | `1800` | hub: how long the PostSync hook waits for the remote secrets |
| `image.repository`, `.tag` | `registry.redhat.io/openshift4/ose-cli-rhel9`, `v4.21` | `oc` image of the hook Jobs; match the tag to the cluster's OpenShift minor |
| `rbac.*` | OpenShift GitOps' controller | hub: Roles that let Argo CD create the hook Jobs and the Kiali CR in `kiali-operator` and `istio-system` |

Sync waves inside each Application: namespace -30, RBAC -20, OLM -10, the Kiali CR 0, the
member's token Secret 5.

## Logging in

The `openshift` login strategy, the only one OSSM supports:

1. Open the hub route, `terraform output kiali_url`
   (`https://kiali-istio-system.<hub apps domain>`), and log in with an account of the hub.
2. For each member, open the user menu (top right), choose "Login to `<member>`" and log in with an
   account of that member. Its OAuth server sends you back to
   `https://kiali-istio-system.<hub apps domain>/api/auth/callback/<member>`, the first redirect URI
   of the member's OAuthClient `kiali-istio-system`.

That is four logins with three members: OpenShift OAuth has no single sign-on across clusters.
Kiali's single-login impersonation needs Kiali 2.30 or later; OSSM 3.4 ships 2.27.

The member's cluster name must be the same everywhere: the end of its redirect URI, the data key
and `kiali.io/cluster` annotation of its remote secret, its Argo CD cluster and ACM ManagedCluster
name, and its Istio `clusterName`. The ApplicationSets pass the one name to all of them.

## Reconcile hook

The operator mounts remote secrets into the Kiali pod only when it reconciles the hub CR, and
External Secrets may create them later. The PostSync hook of `hub-kiali` (Job `kiali-reconcile`
in `istio-system`) waits up to `reconcileHook.timeoutSeconds` for
`kiali-remote-cluster-secret-<member>` of every member in `remoteClusters`, then sets the CR's
annotation `kiali.io/reconcile` to a hash of the member names and their secrets' uids, Red Hat's
documented trigger. A new or recreated secret changes the value and the operator reconciles; the
same secrets keep it, so a later sync costs nothing. The hook runs on every sync of `hub-kiali`,
and a change of the member list causes one: Argo CD does not compare hooks, so the ConfigMap
`istio-system/kiali-remote-clusters` lists the members. On a timeout the hook names the missing
secret and where to look, and fails the sync (Argo CD retries).

When a secret changed between syncs, or the hook failed, trigger the reconcile by hand:

```bash
oc --context <hub-ctx> -n istio-system annotate kialis.kiali.io kiali --overwrite kiali.io/reconcile="$(date +%s)"
oc --context <hub-ctx> -n istio-system wait --for=condition=Successful kialis.kiali.io/kiali --timeout=5m
```

## Token Secret

A member's token Secret syncs at wave 5, after the Kiali CR. Terraform adds a `kiali.io/Kiali`
health check to the ArgoCD CR with the add-on (`argocd.kialiHealthCheck`, `charts/argocd-config`),
so Argo CD waits until the CR reports `Successful`, when the operator has created
`kiali-service-account`. Kubernetes deletes a token Secret whose ServiceAccount does not exist;
Argo CD's self-heal then recreates it. The ApplicationSet ignores the Secret's `data`, which
Kubernetes fills in.

## Removal

Deleting an Application runs the PreDelete Job `kiali-cleanup` in `kiali-operator`. It deletes the
Kiali CRs in `istio-system` and waits up to 300 s while the operator removes what it created
(OAuthClient, roles, ServiceAccount, the server); a CR still there then loses its finalizer, with a
warning. Then it deletes the Subscription and the CSV, as `charts/cert-manager-operator` does.
`terraform/platform` runs the same cleanup per cluster on destroy in case a hook did not run. Left
behind: the hub's `istio-system` (created by Argo CD) and the CRD `kialis.kiali.io`.

## Version drift

`kiali-ossm` has one channel, `stable`, for every Kiali version, and `startingCSV` pins only the
first install. With `installPlanApproval: Automatic` (the repo's OLM pattern) OLM upgrades to each
newer CSV on `stable`, so Kiali can move ahead of the version OSSM 3.4 ships. Check what runs:

```bash
oc --context <hub-ctx> -n kiali-operator get csv
oc --context <mesh-a-ctx> -n kiali-operator get csv
```

Manual approval in `kiali-operator` is a BACKLOG item.

## Graph under the tuning baseline

The tuning baseline (`charts/spoke-ossm`, Telemetry `tuning-metrics`) turns off the client-side
request metrics, so Kiali builds the graph from what the destination proxies report:

- **Still shown:** edges into in-mesh workloads with a sidecar, including cross-cluster edges (the
  destination reads the client's identity from the peer-metadata header, which crosses the
  east-west gateway untouched); mTLS badges; TCP edges.
- **Missing:** edges to namespaces not selected in the graph (select every mesh namespace to get
  most of them back); requests that never reached a destination; ServiceEntry, egress and
  PassthroughCluster destinations; the gateways' request series; throughput edge labels.
- **Metrics tabs:** a workload's default "Outbound metrics" view is empty; set "Reported from" to
  "destination".

The baseline stays: turning it off changes what the scale tests measure. None of this is proven
live yet; no sidecar workloads ran with the add-on.

## Security

- Kiali queries ACM Observability's in-cluster Thanos query-frontend
  (`observability-thanos-query-frontend.open-cluster-management-observability.svc:9090`), which
  has no authentication and serves every cluster's metrics to anything that can reach it on the
  hub. The mutual-TLS Observatorium API path is the hardening follow-up (BACKLOG).
- Kiali holds only the members' `kiali-service-account` tokens (read-only), never the hub's
  cluster-admin kubeconfigs. Users change things with their own login.
