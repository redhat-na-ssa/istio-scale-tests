# acm-observability

OpenShift add-on, off by default. Turns on ACM Observability on the hub: one cluster-scoped
`MultiClusterObservability` (`observability`) and the hub's custom metrics allowlist. Installed by
Terraform (`helm_release.acm_observability` in `terraform/platform/platform_acm_observability.tf`)
when `acm_observability.enabled = true` on `platform = "openshift"`, into
`open-cluster-management-observability`. No ApplicationSet deploys it, so it has no
`values-openshift.yaml`. How to turn it on, check it and turn it off:
[terraform/platform/README.md](../../terraform/platform/README.md#openshift-add-ons-acm-observability-and-kiali).

ACM then runs Thanos, Grafana and the Observatorium API on the hub and a metrics collector on
every managed cluster, the hub included. The collectors push to the hub every `mco.interval`
seconds; Thanos keeps the data in object storage. Kiali on the hub (`charts/kiali`) queries the
in-cluster `observability-thanos-query-frontend` service. The members' Istio metrics come from
`charts/spoke-mesh-metrics`: user workload monitoring, the istiod ServiceMonitor, an Envoy
PodMonitor and a per-namespace allowlist.

## What it renders

- `MultiClusterObservability/observability` (`observability.open-cluster-management.io/v1beta2`):
  - annotation `mco-disable-alerting: "true"`, from the first apply. Without it ACM's endpoint
    operator edits `openshift-monitoring/cluster-monitoring-config` on every cluster: on the
    members Argo CD owns that ConfigMap (`charts/spoke-mesh-metrics`) and would see drift, on a
    ROSA HCP hub HyperShift owns it. ACM's alert forwarding to the hub Alertmanager is off as a
    result.
  - `observabilityAddonSpec`: `enableMetrics: true`, `interval: <mco.interval>`. The chart fails
    below 15 (ACM's minimum).
  - `storageConfig`: the object storage Secret, `storageClass` only when set (else the cluster's
    default StorageClass), and the five volume sizes.
  - `advanced`: `retentionConfig` (raw, 5m and 1h all `mco.retention`), the STS ServiceAccount
    annotations when `mco.roleArn` is set, then `mco.advanced` merged over both.
  - No `instanceSize`: ACM's default size, rated for fewer than 200k active series.
- `ConfigMap/observability-metrics-custom-allowlist` (`hubAllowlist.enabled`), key
  `metrics_list.yaml`, with `hubAllowlist.matches`: ACM adds these to the allowlist of every
  cluster's collector. The default adds istiod's container CPU (`container_cpu_usage_seconds_total`
  in `istio-system`), which Kiali's control-plane panels read.

Terraform creates the rest before the release: the namespace
`open-cluster-management-observability` (it also holds the Helm release), the Secret
`multiclusterhub-operator-pull-secret` (a copy of the hub's `openshift-config/pull-secret`, read at
plan time) and the Secret `thanos-object-storage` (`thanos.yaml`, from `terraform/rosa-hcp`'s
bucket or `acm_observability_object_storage`).
Both Secrets live in the Terraform state, never in git.

## Values

| Value | Default | Purpose |
| --- | --- | --- |
| `mco.name` | `observability` | Name of the MultiClusterObservability (the destroy wait looks for this name) |
| `mco.interval` | `60` | Seconds between the collectors' pushes, at least 15. Terraform: `acm_observability.interval_sec` |
| `mco.retention` | `14d` | Thanos retention of raw, 5m and 1h data. Terraform: `acm_observability.retention` |
| `mco.storageClass` | `""` | Empty: the default StorageClass (`gp3-csi` on ROSA). Terraform: `acm_observability.storage_class` |
| `mco.storageSizes` | 1Gi alertmanager, 20Gi compact, 20Gi receive, 1Gi rule, 10Gi store | Per replica, about 116 GiB in all against the CRD defaults' 436 GiB. Set them before the first apply: later changes need a StorageClass with volume expansion |
| `mco.objectStorageSecret` | `thanos-object-storage` / `thanos.yaml` | The Secret Terraform writes |
| `mco.imagePullSecret` | `multiclusterhub-operator-pull-secret` | The Secret Terraform writes |
| `mco.roleArn` | `""` | STS: the IAM role (`terraform/rosa-hcp`). Empty when `thanos.yaml` holds keys |
| `mco.advanced` | `{}` | Merged over the chart's `spec.advanced`, for example per-component `resources` or `replicas`. Terraform: `acm_observability_values` |
| `hubAllowlist.enabled` | `true` | Render the hub's custom allowlist |
| `hubAllowlist.matches` | istiod's container CPU | `matches:` entries (label matchers) |
| `chartChecksum` | `""` | Set by Terraform so a chart edit rolls out on apply |

## Object storage: STS or static keys

On ROSA, `terraform/rosa-hcp` creates the bucket (`acm_observability_bucket = true`) and an IAM role
that trusts the hub's OIDC provider for the ServiceAccounts
`open-cluster-management-observability:observability-thanos-*`. Terraform writes `thanos.yaml`
without keys and sets `mco.roleArn`; the chart then annotates the compact, store, rule, receive
and query ServiceAccounts with `eks.amazonaws.com/role-arn`, the ACM 2.17 STS recipe, and the
pods get a web identity token. If the Thanos pods get none (no `AWS_ROLE_ARN` in
`oc --context <hub-ctx> -n open-cluster-management-observability get pod observability-thanos-compact-0 -o yaml`,
or S3 `AccessDenied` in that pod's log), set `acm_observability_bucket_static_key = true` in
`terraform/rosa-hcp` and apply both roots: Terraform then puts an IAM user's access key in
`thanos.yaml` and leaves `mco.roleArn` empty.

Outside ROSA (`cluster_provider = "kubeconfig"`) you pass the whole `thanos.yaml` in
`acm_observability_object_storage`, in the format of the ACM Observability docs.

## Interval and retention are shared with Kiali

Kiali reads the metrics through Thanos with `thanos_proxy`, and its `scrape_interval` must equal
`mco.interval`, or its charts stay empty; its `retention_period` is `mco.retention`. Terraform
passes both from the same `acm_observability` values to `charts/kiali`
(`prometheus.scrapeInterval`, `prometheus.retentionPeriod`). Set them through Terraform, not here
alone. A shorter interval makes Kiali's view fresher and sends more samples into the hub: 60 s
sends five times as many as ACM's default of 300 s.

Reference: [ACM 2.17 Observability](https://docs.redhat.com/en/documentation/red_hat_advanced_cluster_management_for_kubernetes/2.17/html-single/observability/index).
