# hub-kiali-remote-secret

OpenShift add-on, off by default (`terraform/platform` `kiali_multicluster`). Hub-only chart, one
release per mesh member: the ApplicationSet `hub-kiali-remote-secret`
(`values-kiali-remote-secret.yaml` in `charts/gitops-hub-ocm-placement-appset`) makes the
Application `<member>-hub-kiali-remote-secret`, which passes `clusterName` and `clusterServer`
(the member's API URL from its Argo CD cluster Secret). Without both the chart renders nothing.
Every member's release is named `kiali-remote-secret` (the preset's `releaseName`: the Application
name would pass Helm's 53-character limit from a 30-character member name), so every object is
named from `clusterName`, the Argo CD sync Roles too (`kiali-<member>-argocd-sync`).

It writes `istio-system/kiali-remote-cluster-secret-<member>`: label
`kiali.io/multiCluster: "true"`, annotation `kiali.io/cluster: <member>`, one data key `<member>`
holding a kubeconfig for the member. The hub's Kiali operator finds it by the label and mounts it
(`charts/kiali`, mode `hub`).

## How it is built

Hop 1, in `external-secrets-operator`: the ExternalSecret `kiali-kubeconfig-<member>` writes the
Secret of the same name, key `kubeconfig`, with:

| Kubeconfig field | Source |
| --- | --- |
| `server` | `clusterServer` |
| `token` | The member's `istio-system/kiali-service-account` token Secret (`charts/kiali`, mode `remote`), read through the SecretStore `kiali-<member>-member` on the member's API. That store authenticates with the `bearer-token` of the hub Secret `kubeconfig-<member>` (`charts/hub-kubeconfig-from-argosecret`) and trusts its `ca.crt` (`memberSecretStore.skipCAProvider: true` for a publicly trusted API) |
| `certificate-authority-data` | `ca.crt` of `kubeconfig-<member>`, read through the SecretStore `kiali-<member>-hub` (ServiceAccount `kiali-<member>-hub-reader`, which may get only that Secret). Left out when empty |

Hop 2, in `istio-system`: the ExternalSecret `kiali-remote-<member>` copies hop 1's kubeconfig into
`kiali-remote-cluster-secret-<member>` through the SecretStore `kiali-<member>-eso` (ServiceAccount
`istio-system/kiali-<member>-reader`, which may get only `kiali-kubeconfig-<member>` in
`external-secrets-operator`).

Why two hops: an ExternalSecret writes only into its own namespace, and a SecretStore reads its
auth Secret only from its own. One hop in `istio-system` would need the member's cluster-admin
token copied into `istio-system`. This way that credential stays in `external-secrets-operator`
and Kiali only ever holds the read-only `kiali-service-account` token.

The member store carries no `hub-mesh-push-secrets/*` label: `charts/hub-mesh-push-secrets` pushes
Istio remote secrets into every store labelled `hub-mesh-push-secrets/push-target=true`, and
`cacerts` into the one labelled with a member's `hub-mesh-push-secrets/cluster-name`.

## Check it

```bash
oc --context <hub-ctx> -n istio-system get externalsecrets,secrets -l kiali.io/multiCluster=true
oc --context <hub-ctx> -n external-secrets-operator get externalsecrets,secretstores -l app.kubernetes.io/name=hub-kiali-remote-secret
```

Every ExternalSecret and SecretStore should be Ready. If hop 1 is not, check that the member's
Application `<member>-kiali` is Healthy and its Secret `istio-system/kiali-service-account` has a
`token` (`oc --context <mesh-a-ctx> -n istio-system get secret kiali-service-account`).

## Removing a member

When a member leaves the Placement its Application goes, and with it the ExternalSecrets; their
Secrets go too (owner reference, `creationPolicy: Owner`). The hub's Kiali drops the cluster at its
next reconcile: Terraform's new member list makes `hub-kiali` sync, and its PostSync hook sets a new
`kiali.io/reconcile` value (`charts/kiali`).
