# --------------------------------------------------------------------------
# OpenShift add-on (off by default): ACM Observability on the hub and the members' Istio
# metrics (acm_observability). Kiali on the hub reads them (platform_kiali.tf).
# --------------------------------------------------------------------------

locals {
  acm_observability_enabled   = local.is_openshift && var.acm_observability.enabled
  addon_gitops                = local.gitops_enabled && var.gitops_app_repo_url != ""
  acm_observability_namespace = "open-cluster-management-observability"

  # rosa: terraform/rosa-hcp's bucket (acm_observability_bucket), null until that root has it.
  acm_observability_rosa_storage     = local.use_kubeconfig ? null : try(data.terraform_remote_state.rosa[0].outputs.acm_observability_storage, null)
  acm_observability_rosa_credentials = local.use_kubeconfig ? null : try(data.terraform_remote_state.rosa[0].outputs.acm_observability_storage_credentials, null)
  # static: an IAM user's key in thanos.yaml. sts: no key; the Thanos ServiceAccounts assume the
  # role through the hub's OIDC provider (charts/acm-observability mco.roleArn).
  acm_observability_static             = try(local.acm_observability_rosa_storage.auth, "") == "static"
  acm_observability_role_arn           = local.acm_observability_static ? "" : try(local.acm_observability_rosa_storage.role_arn, "")
  acm_observability_storage_configured = local.use_kubeconfig ? nonsensitive(var.acm_observability_object_storage != "") : local.acm_observability_rosa_storage != null

  # The thanos-object-storage Secret's thanos.yaml (the ACM Observability docs' S3 format).
  acm_observability_thanos_yaml = local.use_kubeconfig ? var.acm_observability_object_storage : (
    local.acm_observability_rosa_storage == null ? "" : yamlencode({
      type = "s3"
      config = merge(
        {
          bucket             = local.acm_observability_rosa_storage.bucket
          endpoint           = local.acm_observability_rosa_storage.endpoint
          insecure           = false
          signature_version2 = false
        },
        local.acm_observability_static ? {
          access_key = try(local.acm_observability_rosa_credentials.access_key_id, "")
          secret_key = try(local.acm_observability_rosa_credentials.secret_access_key, "")
        } : {},
      )
    })
  )

  # The member metrics ApplicationSet (charts/gitops-hub-apps spoke-mesh-metrics-appset): one
  # Application per mesh member and namespace. Merged into the app-of-apps values only when on.
  mesh_metrics_app_defaults = local.acm_observability_enabled && local.addon_gitops ? {
    "spoke-mesh-metrics-appset" = {
      enabled = true
      values = {
        namespaceMatrix = { namespaces = var.acm_observability.istio_metrics_namespaces }
        template = { source = { helm = { valuesObject = {
          userWorkloadMonitoring = { enabled = var.acm_observability.enable_user_workload_monitoring }
        } } } }
      }
    }
  } : {}
}

resource "kubernetes_manifest" "acm_observability_namespace" {
  count    = local.acm_observability_enabled ? 1 : 0
  provider = kubernetes.hub

  manifest = {
    apiVersion = "v1"
    kind       = "Namespace"
    metadata = {
      name = local.acm_observability_namespace
    }
  }

  computed_fields = ["metadata.labels", "metadata.annotations"]

  field_manager {
    name            = "terraform"
    force_conflicts = true
  }

  depends_on = [time_sleep.wait_acm_multicluster_hub]
}

# The Thanos and Grafana images come from registry.redhat.io; ACM needs the hub's pull secret in
# this namespace (the ACM docs' copy step: MultiClusterHub.spec.imagePullSecret is empty). Read
# at plan time, so a change to the global pull secret reaches it on the next apply.
data "kubernetes_secret_v1" "hub_pull_secret" {
  count    = local.acm_observability_enabled ? 1 : 0
  provider = kubernetes.hub

  metadata {
    name      = "pull-secret"
    namespace = "openshift-config"
  }
}

resource "kubernetes_secret_v1" "acm_observability_pull_secret" {
  count    = local.acm_observability_enabled ? 1 : 0
  provider = kubernetes.hub

  metadata {
    name      = "multiclusterhub-operator-pull-secret"
    namespace = local.acm_observability_namespace
  }

  type = "kubernetes.io/dockerconfigjson"
  data = {
    ".dockerconfigjson" = data.kubernetes_secret_v1.hub_pull_secret[0].data[".dockerconfigjson"]
  }

  # ACM labels Secrets in its namespace for its backup (cluster.open-cluster-management.io/backup);
  # without this every plan removes the label again (2026-10-29 ROSA validation).
  lifecycle {
    ignore_changes = [metadata[0].labels]
  }

  depends_on = [kubernetes_manifest.acm_observability_namespace]
}

resource "kubernetes_secret_v1" "acm_observability_object_storage" {
  count    = local.acm_observability_enabled ? 1 : 0
  provider = kubernetes.hub

  metadata {
    name      = "thanos-object-storage"
    namespace = local.acm_observability_namespace
  }

  type = "Opaque"
  data = {
    "thanos.yaml" = local.acm_observability_thanos_yaml
  }

  lifecycle {
    # ACM's backup label, as on the pull secret above.
    ignore_changes = [metadata[0].labels]

    precondition {
      condition     = local.acm_observability_storage_configured
      error_message = local.use_kubeconfig ? "acm_observability needs the Thanos object storage config: set acm_observability_object_storage (thanos.yaml, as in the ACM Observability docs; pass it with TF_VAR_acm_observability_object_storage)." : "acm_observability needs the Thanos bucket: apply terraform/rosa-hcp with acm_observability_bucket = true first (its output acm_observability_storage is empty)."
    }
  }

  depends_on = [kubernetes_manifest.acm_observability_namespace]
}

# Destroy-time wait between the release's uninstall (it deletes the MultiClusterObservability)
# and the namespace, the Secrets and the spokes: ACM removes every cluster's ObservabilityAddon
# while the spokes are still attached, then the MCO itself. Fails after timeout_sec, naming what
# is left, so the destroy stops before the namespace and the spokes go.
resource "terraform_data" "acm_observability_delete_wait" {
  count = local.acm_observability_enabled ? 1 : 0

  input = {
    token_script    = local.token_script
    hub_api_url     = local.hub_api_url
    hub_admin_pass  = local.hub_admin_pass
    kubeconfig_path = local.kubeconfig
    hub_context     = local.hub_cluster_key
    timeout_sec     = "900"
  }

  provisioner "local-exec" {
    when    = destroy
    command = "bash '${path.module}/../scripts/acm-observability-delete-wait.sh'"
    environment = {
      TOKEN_SCRIPT    = self.input.token_script
      API_URL         = self.input.hub_api_url
      ADMIN_PASS      = self.input.hub_admin_pass
      KUBECONFIG_PATH = self.input.kubeconfig_path
      KUBE_CONTEXT    = self.input.hub_context
      MCO_NAME        = "observability"
      TIMEOUT_SEC     = self.input.timeout_sec
    }
  }

  depends_on = [
    kubernetes_manifest.acm_observability_namespace,
    kubernetes_secret_v1.acm_observability_pull_secret,
    kubernetes_secret_v1.acm_observability_object_storage,
    helm_release.acm_managed_cluster,
    time_sleep.wait_spoke_registration,
  ]
}

# The MultiClusterObservability and the hub's custom allowlist. After the app-of-apps status
# check, so the member metrics Applications have turned on user workload monitoring first: ACM's
# user workload collector starts only once a member's user-workload Prometheus exists.
resource "helm_release" "acm_observability" {
  count    = local.acm_observability_enabled ? 1 : 0
  provider = helm.hub

  name             = "acm-observability"
  chart            = "${path.module}/../../charts/acm-observability"
  namespace        = local.acm_observability_namespace
  create_namespace = false
  take_ownership   = true
  # Helm cannot wait on a custom resource: check the MCO's Ready condition (README).
  wait    = false
  timeout = 600

  # Helm deep-merges the documents in order, so acm_observability_values overrides any key.
  values = [
    yamlencode({
      chartChecksum = local.chart_checksum["acm-observability"]
      mco = {
        interval     = var.acm_observability.interval_sec
        retention    = var.acm_observability.retention
        storageClass = var.acm_observability.storage_class
        roleArn      = local.acm_observability_role_arn
      }
    }),
    yamlencode(var.acm_observability_values),
  ]

  depends_on = [terraform_data.acm_observability_delete_wait, terraform_data.argocd_app_status_check]
}

# Destroy-time safety net per mesh member, for when mesh_metrics_app_cleanup or the root's
# cascade timed out and stripped the Applications' finalizers (Argo CD then deleted nothing):
# deletes what is left with charts/spoke-mesh-metrics' label in the listed namespaces and
# openshift-monitoring, so user workload monitoring does not keep running on the members. A
# cluster-monitoring-config of your own (without that label) is never touched.
resource "terraform_data" "mesh_metrics_member_cleanup" {
  for_each = local.acm_observability_enabled && local.addon_gitops ? local.mesh_member_spoke_set : toset([])

  input = {
    token_script    = local.token_script
    api_url         = local.by_cluster[each.key].cluster_api_url
    admin_pass      = local.admin_password
    kubeconfig_path = local.kubeconfig
    context         = each.key
    namespaces      = join(" ", var.acm_observability.istio_metrics_namespaces)
  }

  provisioner "local-exec" {
    when    = destroy
    command = "bash '${path.module}/../scripts/mesh-metrics-cleanup.sh'"
    environment = {
      TOKEN_SCRIPT    = self.input.token_script
      API_URL         = self.input.api_url
      ADMIN_PASS      = self.input.admin_pass
      KUBECONFIG_PATH = self.input.kubeconfig_path
      KUBE_CONTEXT    = self.input.context
      NAMESPACES      = self.input.namespaces
    }
  }

  # create_before_destroy: see mesh_metrics_app_cleanup (the app-of-apps depends on this one
  # through it).
  lifecycle {
    create_before_destroy = true
  }
}

# Turning acm_observability off: the root Application stops rendering the member metrics
# ApplicationSet but, with prune off, does not delete it. On destroy this deletes the child
# Application once the root no longer wants it; its finalizers remove the generated Applications
# and what they deployed (namespaces Argo CD created stay). Then mesh_metrics_member_cleanup runs
# on each member.
resource "terraform_data" "mesh_metrics_app_cleanup" {
  count = local.acm_observability_enabled && local.addon_gitops ? 1 : 0

  input = {
    token_script     = local.token_script
    hub_api_url      = local.hub_api_url
    hub_admin_pass   = local.hub_admin_pass
    kubeconfig_path  = local.kubeconfig
    hub_context      = local.hub_cluster_key
    gitops_namespace = local.gitops_namespace
    app_names        = "spoke-mesh-metrics-appset"
    appset_names     = "spoke-mesh-metrics"
  }

  provisioner "local-exec" {
    when    = destroy
    command = "bash '${path.module}/../scripts/argocd-app-cleanup.sh'"
    environment = {
      TOKEN_SCRIPT    = self.input.token_script
      API_URL         = self.input.hub_api_url
      ADMIN_PASS      = self.input.hub_admin_pass
      KUBECONFIG_PATH = self.input.kubeconfig_path
      KUBE_CONTEXT    = self.input.hub_context
      GITOPS_NS       = self.input.gitops_namespace
      APP_NAMES       = self.input.app_names
      APPSET_NAMES    = self.input.appset_names
    }
  }

  # The app-of-apps depends on this resource, and Terraform runs an update after the destroy of
  # what the updated resource depends on: turning the add-on off would run this cleanup while the
  # root still renders the ApplicationSet, and its self-heal would recreate it. create_before_destroy
  # reverses that order, so the app-of-apps update comes first. (terraform_data is replaced only
  # through triggers_replace, which this does not use, so nothing else changes.)
  lifecycle {
    create_before_destroy = true
  }

  depends_on = [terraform_data.mesh_metrics_member_cleanup]
}

check "acm_observability_metrics_apps" {
  assert {
    condition     = !local.acm_observability_enabled || local.addon_gitops
    error_message = "acm_observability is on without the app-of-apps (enable_gitops and gitops_app_repo_url): the MultiClusterObservability is installed, but without the app-of-apps no member sends Istio metrics."
  }
}
