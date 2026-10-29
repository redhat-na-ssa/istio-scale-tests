# Multicluster Kiali on the ACM hub: design proposal

**Date:** 2026-10-29.

**Versions this applies to:**
- **Hub:** `<hub>`, ACM 2.17.3, OpenShift GitOps 1.22.2.
- **Mesh members:** `<mesh-a>`, `<mesh-b>` and `<mesh-c>` on ROSA HCP 4.21.11, running OSSM 3.4.3 with Istio v1.30.5.
- **Kiali:** Operator and server 2.27.5, the version that ships with OSSM 3.4.3.

**Confidence tags:** (H) high, (M) medium, (L) low.

Nothing was changed in the repo, on any cluster or in AWS while writing this. The only commands run were read-only `get`, `describe` and `top`.

**As built (2026-10-29).** The add-on was built from this design; where the owner's and the build's
decisions differ from it, they are listed below. Sections 2, 5 and 6 name the built files, values
and variables; the other sections are the proposal as reviewed. Section 12 is unchanged, and the
build follows its requirements. The add-on is not validated live yet
(`BACKLOG.md` section 10); how to run it: [terraform/platform/README.md](../../terraform/platform/README.md#openshift-add-ons-acm-observability-and-kiali).
- **Collection interval 60 s**, not 300 s: `acm_observability.interval_sec = 60` sets the MCO's
  `observabilityAddonSpec.interval` and Kiali's `thanos_proxy.scrape_interval` (`"60s"`) alike.
- **The scraped namespaces are a Terraform list**, `acm_observability.istio_metrics_namespaces`
  (default `istio-system`, `mesh-verify`, `mesh-verify-gwapi`, `mesh-verify-gwapi-shared`): users add
  their own test namespaces there. It must hold `istio-system` and must not hold
  `mesh-verify-gwapi-remote` (the Gateway API check's S7-S9 test a member without it). The scale
  suites' namespaces are not in the default.
- **A separate member chart, `charts/spoke-mesh-metrics`**, with one Argo CD Application per member
  and per listed namespace (`CreateNamespace=true`, so a namespace that does not exist yet never fails
  a sync), instead of a Kiali profile in `charts/istiod-monitor` and a `kialiMetrics` value in the
  mesh-verify charts. `charts/istiod-monitor` and the mesh-verify charts are unchanged; `charts/kiali`
  holds no PodMonitor or allowlist. The `istio-system` release owns `cluster-monitoring-config`
  (switch: `acm_observability.enable_user_workload_monitoring`).
- **The pull secret is copied by Terraform** (`openshift-config/pull-secret` read as a data source,
  written as a `kubernetes_secret_v1`), not by External Secrets. The namespace and both Secrets are
  Terraform resources; `charts/acm-observability` holds only the MCO and the hub allowlist.
- **Re-reconcile by the PostSync hook only:** no `kiali.io/reconcile` annotation rendered from a
  Terraform hash; the hook annotates the CR with a hash of the member secrets' UIDs.
- **No anonymous fallback** (`openshift` only) and no OSSM console plugin.
- **No `lab` size:** the MCO runs at the default instance size, the hub stays enrolled.
- **The Kiali health check is gated by Terraform:** `charts/argocd-config` adds it only while
  `kiali_multicluster` is on (`argocd.kialiHealthCheck.enabled`).
- **Sync waves** 30 (`spoke-mesh-metrics-appset`), 31 (`spoke-kiali-appset`), 32 (`hub-kiali`) and 33
  (`hub-kiali-remote-secret-appset`).
- **Object storage:** a static-key fallback (`acm_observability_bucket_static_key`) next to STS on
  ROSA, and a user-supplied `thanos.yaml` (`acm_observability_object_storage`) in kubeconfig mode.

---

## 1. Recommendation

The design adds two toggles. Both are off by default, work only on OpenShift, and are applied through GitOps.

1. **`acm_observability`** turns on ACM Observability on the hub: one MultiClusterObservability resource, called "MCO" below.
   - The metrics go to Thanos on the hub, which stores them in a new S3 bucket.
   - It uses ACM's **classic metrics collector**, not the newer multicluster observability add-on.
   - Kiali is the first thing that reads these metrics. ACM's built-in Grafana dashboards for all four clusters come as a side benefit.
2. **`kiali_multicluster`** installs Kiali 2.27.5 on the hub in Red Hat's documented **external deployment model**: Kiali runs on a cluster with no Istio and reads the three members remotely. Users log in with **OpenShift accounts**. Each member gets the small set of objects that Kiali and the metrics need.

**What the owner gets:**
- One Kiali UI on the hub, listing namespaces, workloads, services and Istio config validation for all three members.
- A traffic graph and metrics for the namespaces you opt in, which lag by about 5–10 minutes.
- No change to the mesh's tuning baseline.

| Question | Choice | Main reason |
|---|---|---|
| Metrics backend | ACM Observability, classic collector, Thanos + S3 | It is documented by both ACM 2.17 and Kiali 2.27, the Kiali version that actually ships. It adds no new operator; the newer add-on would need the Cluster Observability Operator on the hub. |
| How Kiali queries metrics | The internal hub service `http://observability-thanos-query-frontend.open-cluster-management-observability.svc:9090` with `auth.type: none`, `thanos_proxy.enabled: true`, `scrape_interval` equal to the MCO collection interval, and `retention_period` equal to the MCO retention | Kiali 2.27's ACM page documents it, quoted on v2-27.kiali.io (H). Because Kiali runs on the hub, no certificate copying is needed. |
| Login | `openshift` strategy | OSSM supports only this strategy (H). Each member needs an OAuthClient and a redirect URI. A user signs in four times: once on the hub, then once per member. |
| Kiali's credentials on members | The read-only `kiali-service-account` in `istio-system`, which the Kiali operator creates on each member. A long-lived token for it is copied to the hub by External Secrets. | This is the documented OSSM 3.4 procedure. Keeping the identity in the istiod namespace avoids the Istio 1.30 debug-endpoint restriction. It avoids handing Kiali the cluster-admin Argo token. |
| Kiali namespace | `istio-system` on all four clusters | The OAuthClient name `kiali-istio-system` must be the same on every cluster. On members, Kiali's service account then sits in the same namespace as istiod. |
| What is scraped (v1) | `istio-system` (gateways and istiod) and the mesh-verify namespaces only | This keeps metric volume within the smallest supported MCO size and keeps load off the scale tests. Suite namespaces come later behind a toggle. |
| Tuning baseline (client-side metrics off) | Unchanged | Kiali still draws in-mesh edges from destination-side metrics. The gaps are documented, and turning the baseline off stays a separate owner choice. |
| Hub capacity | Fits on the current 2 × m5.2xlarge | A third node is not needed for capacity (section 7). |

---

## 2. What runs where

| Cluster | Component | Installed by |
|---|---|---|
| **Hub (`<hub>`)** | Namespace `open-cluster-management-observability`, the `thanos-object-storage` secret (key `thanos.yaml`), the pull-secret copy `multiclusterhub-operator-pull-secret` | Terraform resources in `terraform/platform/platform_acm_observability.tf` |
| Hub | MCO resource `observability` (`mco-disable-alerting: "true"`), hub-side custom allowlist | Terraform `helm_release.acm_observability` (new chart `charts/acm-observability`) |
| Hub | Kiali Operator (OLM package `kiali-ossm`, channel `stable`, startingCSV `kiali-operator.v2.27.5`) in its own namespace `kiali-operator` with an AllNamespaces OperatorGroup | Argo child app `hub-kiali` (new chart `charts/kiali`, `mode: hub`) |
| Hub | Namespace `istio-system` (Argo CD `CreateNamespace=true`), Kiali CR `kiali` (external model), the PostSync hook `kiali-reconcile` | same app |
| Hub | One secret per member, `kiali-remote-cluster-secret-<member>`, labelled `kiali.io/multiCluster: "true"`, rendered by External Secrets in two hops | Argo child app `hub-kiali-remote-secret-appset`: ApplicationSet `hub-kiali-remote-secret`, one app per member on the hub; new chart `charts/hub-kiali-remote-secret` |
| **Each member** | Kiali Operator (same chart, namespace `kiali-operator`), a Kiali CR with `deployment.remote_cluster_resources_only: true` and the hub redirect URI, and a `kiali-service-account` token Secret | Argo child app `spoke-kiali-appset`: ApplicationSet `spoke-kiali` (`charts/kiali`, `mode: remote`) |
| Each member | In every listed namespace a PodMonitor `mesh-metrics-istio-proxies` and an `observability-metrics-custom-allowlist` ConfigMap; in `istio-system` also the istiod ServiceMonitor `mesh-metrics-istiod` and `openshift-monitoring/cluster-monitoring-config` with only `enableUserWorkload: true` | Argo child app `spoke-mesh-metrics-appset`: ApplicationSet `spoke-mesh-metrics`, one app per member and namespace (`<member>-mesh-metrics-<namespace>`); new chart `charts/spoke-mesh-metrics` |
| Each member (added by ACM) | endpoint-observability-operator and the metrics collectors | ACM, automatically, once the MCO exists |
| AWS | S3 bucket and an IAM role that the hub's OIDC provider can assume (STS); optionally an IAM user with an access key | Terraform `terraform/rosa-hcp/s3_observability.tf`, behind `acm_observability_bucket` (`acm_observability_bucket_static_key`) |

No Kiali server runs on the members. `remote_cluster_resources_only` creates only a service account, roles and an OAuthClient. Source: kiali-operator v2.27.5 `roles/default/kiali-deploy/tasks/openshift/os-main.yml` lines 44-56 (H).

---

## 3. Metrics path

### 3.1 The data flow

1. **Members:** user-workload monitoring is turned on by creating `cluster-monitoring-config`, which is absent today. Its Prometheus scrapes:
   - istiod, through the repo's existing `istiod` ServiceMonitor, extended as described below;
   - Envoy (`/stats/prometheus`), through a PodMonitor in each opted-in namespace. OpenShift user-workload monitoring ignores `namespaceSelector`, which is why each namespace needs its own PodMonitor. Source: OSSM 3.4 Observability §2.1.2 (H).
2. **Collector:** ACM's `uwl-metrics-collector` on each member federates only the allowlisted names and pushes them to the hub's observatorium-api route every `observabilityAddonSpec.interval`.
   - The allowlist is a ConfigMap `observability-metrics-custom-allowlist` with key `uwl_metrics_list.yaml`, created **in each monitored namespace on the managed cluster**.
   - The ACM 2.17 Observability guide says to "Set the configuration on the managed cluster in namespace where you want to capture the user workload metrics". This text was retrieved for this design (H). https://docs.redhat.com/en/documentation/red_hat_advanced_cluster_management_for_kubernetes/2.17/html-single/observability/index
   - The PodMonitor and the allowlist always travel together, one pair per namespace.
3. **Labels:** the collector adds `cluster=<ManagedCluster name>` and `clusterID` and leaves all other labels as they are. Source: MCO release-2.17 `metrics_collector.go` lines 891-899 (H).
   - Kiali splits clusters by Istio's own `source_cluster` and `destination_cluster` labels. Source: kiali v2.27.5 `graph/telemetry/istio/istio.go` lines 342-347 (H).
   - In this lab the ManagedCluster names equal the Istio `clusterName` values (`<mesh-a>`..`<mesh-c>`), checked live with `get managedcluster` and `get istio default` (H). So leave `query_scope` empty.
4. **Hub:** Thanos receives and stores the data in S3. Kiali queries the in-cluster query-frontend.

### 3.2 Metric names

Kiali needs the following series. This list comes from kiali/kiali `hack/install-acm.sh` (M); start with Kiali's "core" tier:
- `istio_requests_total`
- `istio_request_duration_milliseconds_{bucket,sum,count}`
- `istio_request_bytes_*` and `istio_response_bytes_*`
- `istio_tcp_*`
- `istio_build`
- `pilot_xds`, `pilot_xds_pushes`, `pilot_services`
- `pilot_proxy_convergence_time_{sum,count}`
- `process_cpu_seconds_total` and `process_resident_memory_bytes` for istiod
- a few `envoy_server_*` series

The repo's istiod ServiceMonitor keeps only a fixed `pilot_*` list (`charts/istiod-monitor/templates/servicemonitor.yaml`). It drops `process_*`, `pilot_services` and `istio_build`, and it sets no `targetLabels: [app]`, which the OSSM example does set. Add a value `kiali.enabled` that widens the keep list and adds `targetLabels: [app]`. Leave the default unchanged so the scale tests' measurement profile stays the same.

On the hub, add one `observability-metrics-custom-allowlist` in `open-cluster-management-observability` with key `metrics_list.yaml`. It adds `container_cpu_usage_seconds_total` with a `namespace="istio-system"` match, which Kiali's control-plane panels use.

### 3.3 MCO settings

- `observabilityAddonSpec.interval: 300`, the documented default, exposed as one Terraform value. The same value sets Kiali's `thanos_proxy.scrape_interval`. If the two differ, Kiali shows empty charts, a failure mode quoted from the v2.27 Kiali page (H).
  - Expect about 5–6 minutes of lag and about 10 minutes of warm-up.
  - 60 s is allowed (minimum 15 s) and makes Kiali feel live, but it sends five times as many samples into the hub (owner decision).
- **Retention:** `retentionConfig` of 14d for raw, 5m and 1h data. Kiali's v2.27 page notes at least 10d is required for downsampling. Kiali's `thanos_proxy.retention_period` is also 14d.
- **Storage:** storageClass `gp3-csi` (the live default, which allows volume expansion). Volume sizes:

| Component | Size per replica |
|---|---|
| receive | 20Gi |
| compact | 20Gi |
| store | 10Gi |
| rule | 1Gi |
| alertmanager | 1Gi |

  That totals about 116 GiB, against the CRD defaults of about 436 GiB. These sizes must be set when the MCO is first created (M: MCO release-2.17 types plus the ACM docs).
- **Annotation `mco-disable-alerting: "true"`.** Without it, the endpoint operator edits `cluster-monitoring-config` on every managed cluster. On members it would fight Argo. On the hub the two monitoring ConfigMaps are owned by `hypershift-operator-manager` (field managers checked live). Source: MCO release-2.17 `pkg/config/config.go` lines 58-59 (M).
- **Hub enrolment:** the hub (local-cluster) stays enrolled by default. That costs about 22m CPU and 250Mi, and it gives ACM Grafana hub metrics, which helps watch hub load during scale tests. Excluding it would mean labelling an ACM-owned object (owner decision).
- **Size:** `instanceSize: default`, the supported size rated for fewer than 200k active series. A `lab` value applies Kiali's `install-acm.sh` reduced `spec.advanced` overrides, about 0.6 CPU and 2 GiB of requests. That profile is not a documented supported size, so it is not the default.

### 3.4 Kiali gaps under the unchanged tuning baseline

The baseline sets `tuning-metrics`, which turns off CLIENT-side `REQUEST_*` metrics (`charts/spoke-ossm/templates/tuning-telemetry.yaml`; also live on all three members).

**What still works:**
- Edges into in-mesh sidecar workloads, including cross-cluster edges, built from `reporter="destination"`.
- The mTLS badges.
- TCP edges.

**What is lost** (source: kiali v2.27.5 `istio.go` lines 140-190, `throughput.go`, `MetricsReporter.tsx`; H for the code reading):
- Requests that failed before reaching a destination.
- Egress, ServiceEntry and PassthroughCluster edges.
- Outgoing edges to namespaces not selected in the graph. Selecting all mesh namespaces in the graph recovers most of these.
- Throughput edge labels.
- The default "Outbound metrics" tab. Switching it to "Reported from: destination" brings the series back.

The add-on README should say all of this. Turning the baseline off stays a separate, explicit owner choice, because it changes what the scale tests measure.

---

## 4. Remote access and login

### 4.1 Hub Kiali CR (sketch)

The OSSM 3.4 Observability guide (§4.1.6 "External Kiali deployment model") documents the external model without a Technology Preview label (M on the support statement).

```yaml
apiVersion: kiali.io/v1alpha1
kind: Kiali
metadata: {name: kiali, namespace: istio-system,
  annotations: {kiali.io/reconcile: "<hash of the member list, from Terraform>"}}
spec:
  version: default
  auth: {strategy: openshift}
  clustering: {ignore_home_cluster: true, autodetect_secrets: {enabled: true}}
  kubernetes_config: {cluster_name: "<hub key>"}
  deployment:
    view_only_mode: true
    discovery_selectors:          # field path to confirm against the v2.27 CR reference (M)
      default:
        - matchLabels: {istio-discovery: enabled}
        - matchLabels: {kubernetes.io/metadata.name: istio-system}
    resources: {requests: {cpu: 100m, memory: 256Mi}, limits: {memory: 2Gi}}
  external_services:
    prometheus:
      url: http://observability-thanos-query-frontend.open-cluster-management-observability.svc:9090
      auth: {type: none}
      thanos_proxy: {enabled: true, scrape_interval: 5m, retention_period: 14d}
    grafana: {enabled: false}
    tracing: {enabled: false}
```

### 4.2 Member Kiali CR

The member CR follows OSSM 3.4 Installing §8.7 (H):
- `remote_cluster_resources_only: true`
- `auth.openshift.redirect_uris: ["https://kiali-istio-system.<hub apps domain>/api/auth/callback/<member clusterName>"]`

The operator then creates:
- the `kiali-service-account` service account;
- the read-only `kiali-viewer` role and its binding;
- the OAuthClient `kiali-istio-system`.

Without the redirect URI the operator refuses to reconcile. Source: kiali-operator v2.27.5 `os-main.yml` line 146 (H).

The hub apps domain is read **at apply time** by Terraform from `ingresses.config.openshift.io/cluster` on the hub (`<hub apps domain>`). It is never committed: it lives only in Terraform state and the root Application.

### 4.3 Credentials

1. **Member side.** The member chart ships a Secret named `kiali-service-account`:
   - type `kubernetes.io/service-account-token`
   - annotation `kubernetes.io/service-account.name: kiali-service-account`

   This is OSSM 3.4 Installing §8.7 step 4 (H).
2. **Hub side.** One app per member renders the Secret `kiali-remote-cluster-secret-<member>` in hub `istio-system`. It holds a kubeconfig under the key `<member>` with:

| Kubeconfig field | Source |
|---|---|
| `server` | The `{{server}}` value the ApplicationSet already passes |
| CA | `ca.crt` from the existing hub secret `external-secrets-operator/kubeconfig-<member>`. The ROSA HCP external API CA is captured there by `create-argocd-cluster-secret.sh`. |
| `token` | Read from the member Secret above, by an External Secrets store pointed at the member API |

   - That store authenticates with the existing `kubeconfig-<member>` bearer token. This is the same credential the Istio remote-secret stores already use; it never reaches Kiali.
   - Kiali itself only ever holds the read-only `kiali-service-account` token.
   - Do **not** label any new store `hub-mesh-push-secrets/push-target=true`. `06-pushsecret-remote-secret.yaml` selects every store with that label and would push Istio remote secrets into it.
3. **Pick-up of secrets.** The operator only picks up remote secrets when it reconciles. Two mechanisms force a reconcile:
   - The hub Kiali CR carries `kiali.io/reconcile: <hash of member list>`, so adding or removing a member triggers one.
   - A bounded PostSync hook Job in `hub-kiali` waits until N labelled secrets exist, then annotates the CR. This is the GitOps form of OSSM step 6.
4. **Token creation race.** If the token Secret syncs before the operator has created the service account, Kubernetes' token controller deletes it.
   - Fix: add a `kiali.io/Kiali` health check to `charts/argocd-config` so the in-app sync wave waits until the CR is healthy.
   - Argo self-heal recreates the Secret if the race still happens.
   - Whether OpenShift GitOps 1.22 already includes a Kiali health check is unconfirmed.

### 4.4 Login experience

- Log in on the hub Route.
- Then use "Login to `<member>`" in the profile menu once for each member.
- OpenShift OAuth has no single sign-on across clusters. Kiali's single-login impersonation arrives only in Kiali 2.30 or later; OSSM 3.4 ships 2.27 (H, grep of kiali.io branches).
- The members' only user today is the ROSA htpasswd `cluster-admin`, with the same password on all four clusters. That makes four identical logins workable for a lab.

### 4.5 Fallback login mode

An `auth_strategy = "anonymous"` value can stay as an **unsupported** fallback for headless demos: view-only, no Route, access by `oc port-forward`. It is not the default, because OSSM supports only `openshift` (H).

---

## 5. Repo integration (files to add or change)

### 5.1 New charts

- **`charts/acm-observability/`**, installed by Terraform (`helm_release.acm_observability`, release
  `acm-observability`). It holds the MCO CR `observability` (API `v1beta2`, annotation
  `mco-disable-alerting: "true"`, `observabilityAddonSpec.interval`, retention 14d for raw, 5m and 1h
  data, the volume sizes above, default instance size; with `mco.roleArn` set, the STS
  `eks.amazonaws.com/role-arn` annotation on the Thanos service accounts) and the hub custom
  allowlist. It gets no `values-openshift.yaml`, because no ApplicationSet deploys it.
  Terraform itself creates the Namespace, the `multiclusterhub-operator-pull-secret` copy of
  `openshift-config/pull-secret` (this secret does not exist live and
  `MultiClusterHub.spec.imagePullSecret` is empty, so the ACM 2.17 doc's copy step applies, H) and
  the `thanos-object-storage` Secret, whose `thanos.yaml` holds bucket, endpoint, `insecure: false`
  and `signature_version2: false`, and keys only with the static-key fallback.
- **`charts/kiali/`** has a `mode: hub|remote` value. It contains:
  - `namespace` (`kiali-operator`), `operatorgroup` (AllNamespaces) and `subscription` (`kiali-ossm`, `stable`, startingCSV `kiali-operator.v2.27.5`, Automatic);
  - hub mode: `rbac-argocd` at wave -20, the Kiali CR and the PostSync hook `kiali-reconcile`, which waits for every member's remote secret and then annotates the CR, plus a ConfigMap `kiali-remote-clusters` that lists the members, so a new member list makes `hub-kiali` sync and run the hook again (Argo CD does not compare hooks);
  - remote mode: the remote CR (`remote_cluster_resources_only`, the hub callback as `redirect_uris[0]`) and the token Secret at a later wave;
  - both: a PreDelete hook `kiali-cleanup` that deletes `kialis.kiali.io`, waits for their finalizers, then deletes the Subscription and CSV (as `cert-manager-operator/templates/cleanup-csv.yaml`).

  CRs get `SkipDryRunOnMissingResource`; `values-openshift.yaml` is `{}`.
- **`charts/hub-kiali-remote-secret/`**, one release per member on the hub: the External Secrets stores (member, hub-local in `external-secrets-operator`, and one in `istio-system`), two ExternalSecrets (hop 1 builds the kubeconfig in `external-secrets-operator`, hop 2 copies it to `istio-system` as `kiali-remote-cluster-secret-<member>`), the service accounts and Roles, and the Roles for the Argo controller. Its `values-openshift.yaml` names the OpenShift GitOps controller.
- **`charts/spoke-mesh-metrics/`**, one release per member and namespace: the PodMonitor and the allowlist in that namespace; in `istio-system` also the istiod ServiceMonitor and `cluster-monitoring-config`. The monitors' keep lists and the allowlist come from the same exact-name lists. `values-openshift.yaml` is `{}`.

### 5.2 Changed charts

- **`charts/gitops-hub-ocm-placement-appset/`** gets `namespaceMatrix` (a matrix of the member generator and a list of namespaces, one Application per member and namespace) and three new presets:
  - `values-mesh-metrics.yaml`, deployed to each member and listed namespace, with `CreateNamespace=true`;
  - `values-kiali.yaml`, deployed to each member;
  - `values-kiali-remote-secret.yaml`, run on the hub with one app per member.

  All three are on `OPENSHIFT_ONLY_PRESETS` in `tests/lib/test/chart-platforms.bats`.
- **`charts/gitops-hub-apps/`** gets new templates `spoke-mesh-metrics-appset.yaml`, `spoke-kiali-appset.yaml`, `hub-kiali.yaml` and `hub-kiali-remote-secret-appset.yaml`.
  - Each is gated on `apps.<name>.enabled` **and** `platform == openshift`, as `cert-manager-operator.yaml` does.
  - Each has `enabled: false` in `values.yaml`.
  - Sync waves: 30, 31, 32 and 33, in that order, after the east-west gateways at wave 27.
- **`charts/argocd-config/`** gets `argocd.kialiHealthCheck`, a `kiali.io/Kiali` resource health check that Terraform turns on only while `kiali_multicluster` is on.
- Unchanged: `charts/istiod-monitor/` (installed by hand; with the add-on on, only its PrometheusRule) and the mesh-verify charts.

### 5.3 Tests and docs

- **Tests:** `chart-platforms.bats` (the new charts and presets on the OpenShift-only lists, the matrix shape), `kiali-addon.bats` (the add-on renders on openshift when enabled and never on kubernetes, the remote CR, the reconcile hook, the remote secret, the matrix preset, the health check), `spoke-mesh-metrics.bats`, and the destroy helpers' bats (`argocd-app-cleanup.bats`, `cleanup-olm-csv.bats`, `acm-observability-delete-wait.bats`, `rosa-teardown.bats`). Default renders do not fail when the computed values are empty, because CI renders every preset with defaults (`portability.yml`).
- **Docs:**
  - `charts/README.md`: wave table and charts table; a README per new chart;
  - `README.md`: hub and member namespace tables;
  - `CONTRIBUTING.md`: version pins (`kiali-ossm stable` / `v2.27.5`, MCO API `v1beta2`) and the repo map;
  - `terraform/platform/README.md`: "OpenShift add-ons: ACM Observability and Kiali", and teardown; `terraform/rosa-hcp/README.md`: the bucket;
  - `tests/propagation/README.md`: with the add-on on, `helm install istiod-monitor` only for its PrometheusRule;
  - `BACKLOG.md` section 10;
  - the `docs/runbooks/rosa-validation` runbook after the live run;
  - `STRATEGY.md`.
- **Later, not in v1:** a `kialiMetrics` toggle in the suite charts under `tests/*/chart`, which needs the six-lens review. Also a "Kiali/ACM observability add-on present" line in the TSV platform record (`tests/lib/platform.sh`), so runs with the extra scraping are labelled.

---

## 6. Terraform and AWS additions

### 6.1 `terraform/rosa-hcp` (AWS)

- Two toggles in a new file `s3_observability.tf`: `acm_observability_bucket = false` and, with it, `acm_observability_bucket_static_key = false`. The bucket creates:
  - an `aws_s3_bucket` (`bucket_prefix = "<hub>-acm-obs-"`, so the hub name may have at most 28 characters) with `force_destroy = true`, public access blocked and SSE-S3, so teardown works even with Thanos blocks inside;
  - an `aws_iam_policy` `<hub>-acm-obs-s3` with only `s3:ListBucket`, `GetObject`, `PutObject` and `DeleteObject`, the Thanos runtime minimum (Thanos v0.39.2 `docs/storage.md`, H);
  - an `aws_iam_role` `<hub>-acm-obs-s3` that trusts the **hub's (`<hub>`) OIDC provider** (`create_oidc = true` in the module) for `system:serviceaccount:open-cluster-management-observability:observability-thanos-*`, using `StringLike` so the exact service-account names do not matter;
  - with the static key: an IAM user `<hub>-acm-obs-s3` and an access key, which `terraform/platform` puts in `thanos.yaml` instead of using the role.
- Outputs: `acm_observability_storage` (bucket, region, endpoint, role ARN and `auth`: `sts` or `static`) and the sensitive `acm_observability_storage_credentials` (the static key; null otherwise).
- The teardown audit in `scripts/003-auto-teardown.sh` checks for a leftover bucket, role, user and policy by name. It did not check S3 before.
- **Why here and not in a new AWS root:** the role needs this root's OIDC provider, and in a lab the bucket should die with the clusters. Keeping it here avoids a third root in CI.

### 6.2 `terraform/platform` (cloud-neutral)

**New variables:**
- `acm_observability = { enabled = false, interval_sec = 60, retention = "14d", storage_class = "", istio_metrics_namespaces = ["istio-system", "mesh-verify", "mesh-verify-gwapi", "mesh-verify-gwapi-shared"], enable_user_workload_monitoring = true }`.
- `acm_observability_object_storage`: a sensitive `thanos.yaml` for kubeconfig mode (OpenShift outside ROSA); rosa mode uses the `terraform/rosa-hcp` bucket.
- `acm_observability_values`: extra values for `charts/acm-observability`, merged over Terraform's.
- `kiali_multicluster = { enabled = false, view_only = true }`.
- Validations, following the pattern at the top of `variables.tf`:
  - both require `platform == "openshift"`; Kiali also needs the app-of-apps (`enable_gitops` and `gitops_app_repo_url`);
  - the interval (15 to 3600 s), the retention, the storage class and the namespace list (DNS labels, no duplicates, `istio-system` in, `mesh-verify-gwapi-remote` out);
  - a `check` block warns (but does not block) when Kiali is on and observability is off; Kiali works without it but the graph is empty.

**New file `platform_acm_observability.tf`:**
- The namespace, the pull-secret copy and `thanos-object-storage` (in ROSA mode from the `terraform/rosa-hcp` outputs, read through `terraform_remote_state`).
- `helm_release.acm_observability`, after `terraform_data.argocd_app_status_check`, so the member metrics apps have turned user workload monitoring on first.
- `terraform_data.acm_observability_delete_wait`. The helm release depends on it, so on destroy its destroy-time provisioner (`terraform/scripts/acm-observability-delete-wait.sh`) runs **after** helm uninstall. It waits up to 15 minutes for the MCO and every ObservabilityAddon to be gone before the MultiClusterHub and the spokes are torn down.
- The `spoke-mesh-metrics-appset` values (namespace list, user workload monitoring switch) and `terraform_data.mesh_metrics_app_cleanup`.

**New file `platform_kiali.tf`:**
- `data "kubernetes_resource"` for the hub ingress domain, which gives the hub Route `kiali-istio-system.<hub apps domain>`, the members' callback base `https://kiali-istio-system.<hub apps domain>/api/auth/callback` and the output `kiali_url`.
- The values of `hub-kiali` (`clusterName` = the ACM local cluster name, `remoteClusters` = the members, `viewOnly`, the interval and retention), `spoke-kiali-appset` (`hubRedirectBase`, `viewOnly`) and `hub-kiali-remote-secret-appset`.
- `terraform_data.kiali_app_cleanup`, with a destroy provisioner (`terraform/scripts/argocd-app-cleanup.sh`, `APP_NAMES` mode) that cascade-deletes the three Kiali child Applications. The root syncs with `prune: false` (`gitops-hub-app-of-apps/values.yaml`), so this resource is how switching the toggle off actually removes them; `mesh_metrics_app_cleanup` does the same for the metrics apps.
- `terraform_data.kiali_cr_cleanup` for the hub and each member, modelled on `spoke_ossm_csv_cleanup`. It deletes any Kiali CR left in `istio-system` (stripping a stuck finalizer), then the Subscription and CSV, and it is added to `argocd_app_cleanup.depends_on`.

**Elsewhere:**
- `platform_gitops.tf`: the add-on app values go into the app-of-apps release as their own document, only when non-empty, between `provider_app_defaults` and `gitops_app_overrides` (with both toggles off the release values do not change); `argocd.kialiHealthCheck.enabled` is set on `helm_release.argocd_config` only while Kiali is on.
- `main.tf`: `acm-observability` in `chart_checksum`.
- CI (`.github/workflows/portability.yml`) runs `terraform fmt` and `validate` on both roots, as before.

### 6.3 Destroy order

Turning `kiali_multicluster` off (one apply):
1. The app-of-apps release is updated first: the root stops rendering the three Kiali children (with `prune: false` it does not delete them).
2. `kiali_app_cleanup` waits until the root no longer wants them and deletes them. Their finalizers cascade: the ApplicationSets, the generated Applications, the PreDelete hooks (each Kiali CR, then the Subscription and CSV), then the rest; the hub remote secrets go with their ExternalSecrets.
3. `kiali_cr_cleanup` is the safety net on each cluster.
4. `argocd_config` drops the Kiali health check.

Left behind: the hub `istio-system` namespace and the CRD `kialis.kiali.io`.

Turning `acm_observability` off: `mesh_metrics_app_cleanup` deletes the metrics apps (namespaces they created stay), and `helm_release.acm_observability` is uninstalled while the spokes are still attached; `acm_observability_delete_wait` waits for the MCO and the ObservabilityAddons to go; then the Secrets and the namespace go.

A full destroy runs `argocd_app_cleanup` (the root's cascade), the cleanups above, `kiali_cr_cleanup` and the existing `spoke_ossm_csv_cleanup`, and in parallel the MCO chain, which completes before the MultiClusterHub and the ManagedClusters go. The `rosa-hcp` destroy then deletes the bucket, the role, the policy and the user.

The observability volumes are deleted along with their namespace (gp3-csi reclaim policy is Delete). The auto-teardown audit's EBS check would catch any leak.

---

## 7. Capacity and cost

### 7.1 Hub today (live)

Measured on 2026-10-29 with `kubectl --context <hub-ctx> describe nodes` and `top nodes`:

| Node | Instance | CPU requested | Memory requested | CPU limits | Memory limits |
|---|---|---|---|---|---|
| hub node 1 | m5.2xlarge | 4420m (58%) | 15532Mi (50%) | 96% | 95% |
| hub node 2 | m5.2xlarge | 3276m (43%) | 14603Mi (47%) | 63% | 67% |

- **Total requested:** 7.7 of 15 CPU and 29.4 of 59.6 GiB.
- **Actual use:** about 1.1 CPU (7%) and 15.5 GiB (26%).
- **Request headroom:** about 7.3 CPU and 30 GiB.

### 7.2 What the add-ons add on the hub

| Item | CPU requests | Memory requests | Source |
|---|---|---|---|
| MCO, default size | 2701m | 11972Mi | ACM 2.17 pod capacity table, quoted (H) |
| Hub's own collectors (hub enrolled) | ~22m | ~250Mi | MCO source (M) |
| Kiali server | 100m | 256Mi (limit 2Gi) | proposed |
| Kiali operator | ~50m | ~128Mi | budget only; not measured (L) |
| **Total** | **~2.9 CPU** | **~12.6 GiB** | |

### 7.3 Result

- **Total requested after the change:** about 10.6 of 15 CPU (70%) and about 42 of 59.6 GiB (71%).
- **Busier node,** if the new pods split evenly: about 5.9 of 7.5 CPU (78%).
- The MCO uses only *preferred* anti-affinity (MCO release-2.17 manifests, M), so its three-replica parts can share the two nodes.
- **No third hub node is needed for capacity.**
- **Caveats:**
  - The hub already cannot survive losing a node: 7.7 CPU of requests is more than one node's 7.5 CPU, and the MCO widens that gap. A third m5.2xlarge would be an **availability** choice, not a capacity requirement.
  - One node's limits are already at 96%. Watch actual use after enabling, especially thanos-receive memory, which grows with series count.
  - The `lab` size (about 0.6 CPU and 2 GiB) is the fallback if actual use is tight.

### 7.4 Members

Each member gets:
- the user-workload monitoring stack (two Prometheus replicas, thanos-ruler and prometheus-operator);
- collectors at about 22m CPU and 250Mi;
- one Kiali operator pod;
- no Kiali server.

Members today sit at 30–44% CPU and 50–63% memory requests on 2 × m7i.xlarge (live). The user-workload Prometheus memory is the constraint to watch. It is the reason v1 scrapes only `istio-system` and mesh-verify.

### 7.5 Cost

These are estimates (M):

| Item | Size | Cost |
|---|---|---|
| gp3 volumes, proposed sizes | ~116 GiB | ≈ $9.3/month ≈ $0.31/day at $0.08 per GB-month |
| gp3 volumes, default sizes (for comparison) | ~436 GiB | ≈ $35/month |
| S3 | a few GB at 14-day retention | under $1/month |

---

## 8. Live validation plan

These steps make changes, so they run only in an approved window.

1. **Read-only pre-checks.**
   - `get packagemanifest kiali-ossm` still shows `stable` → `v2.27.5`.
   - The MCO CRD serves `v1beta2`.
   - Member DNS resolves the hub `*.apps` domain. Members must push to the hub observatorium-api route directly; the ACM docs say load balancers and proxies are not supported (M).
2. **Storage.**
   - Apply `rosa-hcp` with `acm_observability_bucket = true`.
   - Check: `aws s3api head-bucket`, and that the IAM role trust policy names the hub's (`<hub>`) OIDC provider.
3. **Observability.**
   - Apply `platform` with `acm_observability.enabled = true`.
   - `oc get mco observability -o jsonpath='{.status.conditions}'` shows Ready.
   - All pods in `open-cluster-management-observability` are Running.
   - The thanos-store and thanos-compact pods have `AWS_ROLE_ARN` and `AWS_WEB_IDENTITY_TOKEN_FILE` set (proof that STS was injected), and the compact logs show no S3 errors.
   - `oc get managedclusteraddon -A | grep observability` shows the add-on Available on all four clusters.
   - Port-forward to the query-frontend and run `count(up) by (cluster)`; it returns four clusters.
   - After about 2 hours, `aws s3 ls` shows blocks in the bucket.
4. **Kiali.**
   - Enable `kiali_multicluster`.
   - Hub and member Kiali CRs show condition `Successful`.
   - `oc get oauthclient kiali-istio-system -o jsonpath='{.redirectURIs}'` on each member shows the right callback.
   - The hub has three `kiali.io/multiCluster=true` secrets.
   - The Kiali pod logs list three clusters.
   - User-workload pods run on the members, and `up{namespace="istio-system"}` is 1 in each member's thanos-querier.
5. **Traffic.**
   - Run mesh-verify (its namespace is in the default `istio_metrics_namespaces`) so it produces cross-cluster calls.
   - After interval + 10 minutes, `sum by (source_cluster,destination_cluster,source_workload)(istio_requests_total{reporter="destination"})` in Thanos shows cross-cluster rows with `source_workload != "unknown"`.
   - The Kiali graph shows edges between cluster boxes.
   - Walk through the four logins, either by hand or with Playwright.
6. **Load.** After 1 hour, record in BACKLOG:
   - `oc adm top pods -n open-cluster-management-observability`;
   - the hub node requests;
   - `max(prometheus_tsdb_head_series)` from the member user-workload Prometheus;
   - thanos-receive head series.
7. **Teardown.**
   - Switch the toggles off: the child apps are deleted and no Kiali CR is left stuck.
   - Run a full destroy: no leftover volumes, the bucket is gone, and the auto-teardown audit is clean.
8. **CI.** `tests/lib/verify.sh`, bats, and the kubernetes render proving the add-on is absent.

---

## 9. Risks and unknowns

- **Support statement.** No Red Hat document ties OSSM 3 to ACM. Grepping the OSSM 3.4 guides and the ACM 2.17 Observability guide gives 0 hits (H). The combination is supported only piece by piece; kiali.io is the integration reference. Ask Red Hat if a support statement matters.
- **Kiali at scale.** Upstream performance tests stop at 800 namespaces. Behaviour at thousands of mesh namespaces across three clusters with one replica and a 2Gi limit is untested (M). Discovery selectors and manual graph refresh reduce the risk.
- **Metric volume if suite namespaces are added.** Raw per-pod Istio histograms across three clusters can plausibly exceed the default MCO rating of 200k series (estimate, L). The fixes are to aggregate at the edge or keep to a subset of namespaces.
- **User-workload monitoring persistence on ROSA HCP.** A Red Hat knowledge-base article behind login (access.redhat.com/node/7130030) reportedly warns that HCP monitoring-config edits may be reverted. Current ROSA docs say to create the ConfigMap, and the SRE webhook does not block it (live, M).
- **Istio 1.30 debug-endpoint authorization.** It is on by default and may limit Kiali reading remote istiod debug data. Keeping Kiali's identity in `istio-system` follows the release-note guidance, but this is not verified for a hub-hosted Kiali (L).
- **Kiali version drift.** `kiali-ossm` has no per-minor channel (live). With Automatic approval on `stable`, Kiali can move ahead of OSSM 3.4. Pinning startingCSV only pins the first install. Option: Manual approval in the dedicated `kiali-operator` namespace plus an approval step.
- **STS on ROSA HCP.** ACM 2.17 documents `serviceAccountAnnotations` with `eks.amazonaws.com/role-arn` (quoted, H). That the ROSA HCP pod-identity webhook injects credentials into the Thanos pods is M. Fallback: a static IAM user key in `thanos.yaml`, created by Terraform as a `kubernetes_secret_v1`.
- **OSSM console plugin (OSSMC) on a hub without Istio.** Undocumented, so it stays off.
- **Nothing is proven end to end yet.** There are no sidecar workloads live (only gateways), so nothing about the metrics path is proven against live data.
- **Observer effect.** User-workload Prometheus and the collectors add load on members during runs. Keep the add-on off for measurement windows, or record its presence in the platform record.
- **Credential hygiene.** The live probe reported that the shared cluster-admin password appeared once in a research agent's tool output. The kubeconfig stores it as plain text in an exec argument. Rotating it is advised. The design never reuses that credential.

---

## 10. Rejected alternatives

- **ACM multicluster observability add-on (MCOA) with the Cluster Observability Operator (COO).** It is the forward path: it allows a fast scrape interval per job and pre-aggregates Istio series on each member, and it has been documented since ACM 2.15 without a Technology Preview label (M). It is deferred because it needs:
  - COO on the hub;
  - Argo co-owning the ClusterManagementAddOn that the MCO creates;
  - the `namespacesWithoutLabelEnforcement` setting on members.

  Its Kiali recipe also exists only in the v2.33+ Kiali docs, newer than what OSSM ships. Revisit it when suite-namespace metrics at scale are wanted.
- **Federating per-member Prometheus into a hand-built hub Thanos.** More custom code, and community or third-party Prometheus integrations are "not supported by Red Hat" (OSSM 3.4 feature table, H). ACM already ships Thanos.
- **The hub's own thanos-querier.** It holds no member metrics (H).
- **One Kiali per member.** This contradicts the owner's decision to run Kiali on the hub.
- **Reusing the `kubeconfig-<member>` or Istio remote secrets for Kiali.** That would give Kiali cluster-admin on every member.
- **A ManagedServiceAccount for Kiali.** It would rotate its token automatically, but its service account lives outside `istio-system` (the debug-endpoint concern) and it would have to bind to an operator-internal role name. Revisit if token rotation matters.
- **`token` auth.** "Untested and considered experimental" for external Kiali in v2.27 (H).
- **Impersonation (single login).** Needs Kiali 2.30 or later (H).
- **Observatorium mutual-TLS query path.** Kiali recommends it for production; it is a hardening follow-up. External Secrets can sync the rotating `observability-grafana-certs`.
- **rbac-query-proxy with a bearer token.** Not documented for Kiali, and on an authentication failure it returns HTTP 200 with an empty result (MCO `proxy.go`, H), which is hard to debug.
- **The bucket in a separate AWS root.** That would add a third root to CI and teardown, and it would still need the `rosa-hcp` OIDC provider.

---

## 11. Where the research disagreed, and the default chosen

| Disagreement | Default chosen |
|---|---|
| **Login.** The Kiali upstream researcher suggested anonymous for a harness; the OSSM researcher found that OSSM supports only `openshift`. | `openshift`. Anonymous remains an opt-in, unsupported value. |
| **Where the allowlist goes.** The ACM researcher found in the MCO source that a hub-side `uwl_metrics_list.yaml` in `open-cluster-management-observability` is merged and sent to every cluster; the Kiali v2.27 page says per source namespace. | The ACM 2.17 doc (retrieved) documents the per-namespace placement on the managed cluster. Default: per namespace, paired with the PodMonitor. The hub-side placement is noted as an unverified alternative. |
| **STS.** One researcher found no ACM STS doc. | The ACM 2.17 STS text was retrieved and quoted. Default: STS, with a static-key fallback. |
| **MCO sizing source.** The live-probe researcher cited older docs for 2701m / 11972Mi. | The ACM 2.17 table was retrieved and gives the same numbers (H). |
| **Kiali namespace.** One researcher proposed a dedicated `kiali` namespace. | `istio-system` everywhere, because of the OAuthClient name and the Istio 1.30 debug-endpoint note. |


---

## 12. Independent verification (2026-10-29)

Four load-bearing claims were each given to a separate checker told to refute them from primary
sources (Red Hat docs, upstream source at the running versions, read-only live checks). All four
held. The checkers added these requirements, which the build must follow:

- **Kiali external model:** the remote secrets are mounted only when the operator reconciles, so a
  secret that External Secrets creates later needs the hub Kiali CR re-reconciled (Red Hat's step:
  annotate the CR). The callback URI's cluster name must equal the remote secret's cluster name and
  the Istio `clusterName`, and must be the first `redirect_uris` entry (the server uses index 0).
  `istio-system` must be created on the hub.
- **ACM allowlist:** `names` entries are exact names (`istio_*` matches nothing). Use
  `matches: ['__name__=~"istio_.*"']` or list every `_bucket`/`_sum`/`_count` name. `pilot_*` needs
  an allowlist in `istio-system`. The UWM collector only starts once the members' user-workload
  Prometheus exists, so UWM comes first.
- **UWM ConfigMap on ROSA HCP:** put `mco-disable-alerting: "true"` on the MultiClusterObservability
  resource from the first apply, else the ACM endpoint operator becomes a field manager of the
  GitOps-owned `cluster-monitoring-config` and Argo CD sees drift. Set only `enableUserWorkload: true`
  in it. After the first sync, check that its managedFields show only Argo CD.
- **Graph under the tuning baseline:** in-mesh and cross-cluster edges hold (the destination sidecar
  reads the client's identity from the peer-metadata header, which passes the east-west gateway
  untouched). Missing: edges to unselected namespaces, requests that never reached a destination,
  ServiceEntry/egress destinations, gateway request series and request-throughput labels. TCP edges
  are unaffected. Not yet proven live: no sidecar workloads run yet.
- **Security:** the hub's internal Thanos query-frontend (`:9090`) has no authentication and serves
  every cluster's metrics. The mTLS Observatorium path is the hardening follow-up.
