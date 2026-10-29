# gitops-hub-apps

Helm chart rendered by the root Application `hub-gitops-root`
(`charts/gitops-hub-app-of-apps`). It creates the child Argo CD Applications; sync waves
are listed in [`../README.md`](../README.md).

| Value | Default | Purpose |
| --- | --- | --- |
| `platform` | `kubernetes` | `kubernetes`: upstream operator charts, members from the Argo CD cluster Secrets; `openshift`: Red Hat operators (OLM), members from the ACM Placement |
| `gitopsNamespace` | `argocd` (`openshift-gitops` on OpenShift) | Namespace of the child Applications |
| `repo.url` | `""` (required) | Git URL for every child Application and ApplicationSet |
| `repo.revision` | `main` | Git revision for the same |
| `certManager.repoURL`, `.chart`, `.version` | `https://charts.jetstack.io`, `cert-manager`, `v1.21.2` | The upstream cert-manager chart (`hub-cert-manager-operator`, kubernetes only); `apps.hub-cert-manager-operator.source` overrides them, e.g. for a chart mirror |
| `apps.<name>.enabled` | `true` | Render that child Application |
| `apps.<add-on>.enabled` | `false` | The OpenShift add-ons `spoke-mesh-metrics-appset`, `spoke-kiali-appset`, `hub-kiali` and `hub-kiali-remote-secret-appset` (waves 30 to 33). `terraform/platform` turns them on (`acm_observability`, `kiali_multicluster`) and sets their values; they never render on `kubernetes` |

Disable an app when that operator is already installed, e.g.
`apps.hub-cert-manager-operator.enabled=false`.
