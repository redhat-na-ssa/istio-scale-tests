# spoke-mesh-metrics

The member side of the OpenShift add-on `acm_observability`
([terraform/platform/README.md](../../terraform/platform/README.md#openshift-add-ons-acm-observability-and-kiali)):
it gets a mesh member's Istio metrics to ACM Observability on the hub, where the hub's Kiali reads
them. OpenShift only, off by default. It adds the user-workload Prometheus and its scraping to the
member, so keep the add-on off while a suite measures.

One release covers one namespace of one member. The ApplicationSet `spoke-mesh-metrics` (preset
`values-mesh-metrics.yaml` of `charts/gitops-hub-ocm-placement-appset`, child Application
`spoke-mesh-metrics-appset`) makes one Application per member and per namespace in
`acm_observability.istio_metrics_namespaces`, named `<member>-mesh-metrics-<namespace>`.

| In | Object | Why |
| --- | --- | --- |
| every listed namespace | PodMonitor `mesh-metrics-istio-proxies` | Scrapes the Envoy proxies (sidecars and gateways) at `/stats/prometheus`. OpenShift user workload monitoring ignores `namespaceSelector`, so each namespace needs its own |
| every listed namespace | ConfigMap `observability-metrics-custom-allowlist` (key `uwl_metrics_list.yaml`) | ACM's `uwl-metrics-collector` sends a namespace's series to the hub only when its allowlist there names them |
| `istio-system` only | ServiceMonitor `mesh-metrics-istiod` | istiod's metrics, with its `app` label, for Kiali's control-plane views |
| `istio-system` only | `openshift-monitoring/cluster-monitoring-config` with only `enableUserWorkload: true` | Turns on user workload monitoring, the Prometheus the monitors feed (`userWorkloadMonitoring.enabled`) |

Both monitors keep only the names in `istiodMetrics` and `proxyMetrics`, and the allowlist lists
the same names, so a kept series is always sent and an allowlisted one always kept. The names are
exact: ACM's `names:` matches whole names, not patterns (`istio_*` matches nothing), so a pattern in
either list fails the render. Both scrape every 60 s (`scrapeInterval`): ACM's collector sends
every `observabilityAddonSpec.interval` (60 s, `acm_observability.interval_sec`), so faster
scraping only adds load on the member.

## Namespaces

Terraform passes the list (`acm_observability.istio_metrics_namespaces`, default `istio-system`,
`mesh-verify`, `mesh-verify-gwapi` and `mesh-verify-gwapi-shared`). To see a test namespace of your
own in Kiali's graph and metrics, add it there and apply `terraform/platform`; removing it deletes
its Application (and its PodMonitor and allowlist) on the next apply. The scale suites' namespaces
are not in the default: their proxies would add load and series during a measurement.

The list must hold `istio-system` and must never hold `mesh-verify-gwapi-remote` (Terraform's
validation refuses both mistakes): every listed namespace is created on every member (below), and
the Gateway API check's S7-S9 test a member without that one.

Each Application syncs with `CreateNamespace=true`, so a listed namespace that does not exist yet
(mesh-verify is deployed on demand) never fails a sync. Two things follow:

- While a namespace is listed, it exists: when mesh-verify deletes its own namespace, Argo CD's
  self-heal creates it again, without workloads, to hold the PodMonitor and the allowlist.
- A namespace an Application created stays when the add-on is turned off or the namespace leaves
  the list (Argo CD deletes the monitors and the allowlist, not the namespace).

Delete such a namespace by hand once it is off the list and nothing else uses it:

```bash
oc --context <mesh-a-ctx> delete namespace mesh-verify
```

## User workload monitoring

The `istio-system` release owns `openshift-monitoring/cluster-monitoring-config` (wave -10, before
the monitors). The MultiClusterObservability carries `mco-disable-alerting: "true"`
(`charts/acm-observability`), which keeps ACM's endpoint operator from editing this ConfigMap, so
Argo CD is its only writer. After the first sync its managedFields should name only Argo CD:

```bash
oc --context <mesh-a-ctx> -n openshift-monitoring get cm cluster-monitoring-config --show-managed-fields -o yaml
```

A member that already has this ConfigMap (with other cluster monitoring settings) needs
`acm_observability.enable_user_workload_monitoring = false`: then add `enableUserWorkload: true` to
it yourself. Turning the add-on off deletes the ConfigMap, and with it user workload monitoring.

User workload monitoring comes first: ACM's `uwl-metrics-collector-deployment` starts only once the
member's user-workload Prometheus exists. If it is still missing after the pods in
`openshift-user-workload-monitoring` run, restart the member's ACM endpoint operator:

```bash
oc --context <mesh-a-ctx> -n openshift-user-workload-monitoring get pods
oc --context <mesh-a-ctx> -n open-cluster-management-addon-observability get deploy uwl-metrics-collector-deployment
oc --context <mesh-a-ctx> -n open-cluster-management-addon-observability rollout restart deploy/endpoint-observability-operator
```

## With charts/istiod-monitor

`charts/istiod-monitor` (installed by hand for the propagation suite) overlaps this chart: its
ServiceMonitor `istiod` scrapes istiod a second time, and its `enableUserWorkloadMonitoring` writes
the same `cluster-monitoring-config`. With the add-on on, install only its PrometheusRule:

```bash
helm install istiod-monitor charts/istiod-monitor -n istio-system --kube-context <mesh-a-ctx> \
  --set enableUserWorkloadMonitoring=false --set serviceMonitor.enabled=false
```

## Check it

```bash
oc --context <hub-ctx> -n openshift-gitops get applications.argoproj.io | grep mesh-metrics
oc --context <mesh-a-ctx> get podmonitors,servicemonitors,cm -A | grep -E 'mesh-metrics|custom-allowlist'
```

References: [OSSM 3.4 Observability, metrics](https://docs.redhat.com/en/documentation/red_hat_openshift_service_mesh/3.4/html/observability/metrics-and-service-mesh)
(the PodMonitor's relabelings), [ACM 2.17 Observability, adding user workload metrics](https://docs.redhat.com/en/documentation/red_hat_advanced_cluster_management_for_kubernetes/2.17/html-single/observability/index)
(the allowlist), [Kiali, ACM Observability](https://kiali.io/docs/configuration/multi-cluster/acm-observability/).
