# --------------------------------------------------------------------------
# OpenShift add-on (off by default): one Kiali on the ACM hub for every mesh member
# (kiali_multicluster), in Red Hat's external deployment model. Argo CD deploys it through
# the app-of-apps (charts/kiali, charts/hub-kiali-remote-secret); its metrics come from ACM
# Observability (platform_acm_observability.tf).
# --------------------------------------------------------------------------

locals {
  kiali_enabled = local.is_openshift && var.kiali_multicluster.enabled

  # The hub's Route kiali in istio-system has no host, so OpenShift gives it
  # kiali-istio-system.<apps domain>: spec.appsDomain when set, else spec.domain. Each member's
  # OAuthClient lists the hub's callback for that member, <base>/<member>. Read at plan time;
  # the domain is kept only in the state and the root Application, never in git.
  kiali_hub_apps_domain = try(coalesce(
    try(data.kubernetes_resource.hub_ingress_config[0].object.spec.appsDomain, ""),
    try(data.kubernetes_resource.hub_ingress_config[0].object.spec.domain, ""),
  ), "")
  kiali_hub_host      = "kiali-istio-system.${local.kiali_hub_apps_domain}"
  kiali_redirect_base = "https://${local.kiali_hub_host}/api/auth/callback"

  # The three Kiali child apps of charts/gitops-hub-apps. A for expression, not a conditional:
  # the apps' values differ in type, which a conditional with {} cannot unify.
  kiali_app_defaults = { for k, v in {
    "hub-kiali" = {
      enabled = true
      values = {
        # kubernetes_config.cluster_name: the hub's own ACM cluster name.
        clusterName = local.acm_local_cluster_name
        # The members whose remote secrets the PostSync hook waits for before it re-reconciles.
        remoteClusters = local.mesh_member_spoke_keys
        viewOnly       = var.kiali_multicluster.view_only
        # thanos_proxy: the same interval and retention as the MultiClusterObservability.
        prometheus = {
          scrapeInterval  = "${var.acm_observability.interval_sec}s"
          retentionPeriod = var.acm_observability.retention
        }
      }
    }
    "spoke-kiali-appset" = {
      enabled = true
      values = { template = { source = { helm = { valuesObject = {
        hubRedirectBase = local.kiali_redirect_base
        viewOnly        = var.kiali_multicluster.view_only
      } } } } }
    }
    "hub-kiali-remote-secret-appset" = { enabled = true }
  } : k => v if local.kiali_enabled && local.addon_gitops }

  # Both add-ons' app-of-apps values (their keys differ); platform_gitops.tf adds them as one
  # values document only when one of them is on.
  addon_app_defaults = merge(local.mesh_metrics_app_defaults, local.kiali_app_defaults)
}

data "kubernetes_resource" "hub_ingress_config" {
  count    = local.kiali_enabled ? 1 : 0
  provider = kubernetes.hub

  api_version = "config.openshift.io/v1"
  kind        = "Ingress"

  metadata {
    name = "cluster"
  }

  lifecycle {
    postcondition {
      condition     = try(self.object.spec.domain, "") != ""
      error_message = "kiali_multicluster: the hub's ingresses.config.openshift.io/cluster has no spec.domain, so the plan cannot build Kiali's route host and the members' OAuth callback URIs."
    }
  }
}

# Destroy-time safety net per cluster (the hub and every mesh member), for when the PreDelete
# hooks of charts/kiali did not run (an Application force-deleted): deletes any Kiali CR left in
# istio-system (stripping its finalizer after the wait), then the kiali-ossm Subscription and its
# CSV. The script matches CSVs by name, and kiali-ossm's CSV is kiali-operator.v<version>.
resource "terraform_data" "kiali_cr_cleanup" {
  for_each = local.kiali_enabled && local.addon_gitops ? toset(concat([local.hub_cluster_key], local.mesh_member_spoke_keys)) : toset([])

  input = {
    token_script    = local.token_script
    api_url         = local.by_cluster[each.key].cluster_api_url
    admin_pass      = local.admin_password
    kubeconfig_path = local.kubeconfig
    context         = each.key
    sub_namespace   = "kiali-operator"
    sub_name        = "kiali-ossm"
    package_name    = "kiali-operator"
    delete_crs      = "kialis.kiali.io:istio-system"
  }

  provisioner "local-exec" {
    when    = destroy
    command = "bash '${path.module}/../scripts/cleanup-olm-csv.sh'"
    environment = {
      TOKEN_SCRIPT    = self.input.token_script
      API_URL         = self.input.api_url
      ADMIN_PASS      = self.input.admin_pass
      KUBECONFIG_PATH = self.input.kubeconfig_path
      KUBE_CONTEXT    = self.input.context
      SUB_NAMESPACE   = self.input.sub_namespace
      SUB_NAME        = self.input.sub_name
      PACKAGE_NAME    = self.input.package_name
      DELETE_CRS      = self.input.delete_crs
    }
  }

  # create_before_destroy: see kiali_app_cleanup. The app-of-apps depends on this one too (through
  # kiali_app_cleanup), so without it turning the add-on off would run this before the
  # app-of-apps update, while the root still deploys Kiali.
  lifecycle {
    create_before_destroy = true
  }
}

# Turning kiali_multicluster off: the root Application stops rendering the three Kiali child
# apps but, with prune off, does not delete them. On destroy this deletes them once the root no
# longer wants them; their finalizers remove the generated Applications, whose PreDelete hooks
# delete each Kiali CR (the operator removes its OAuthClient, roles and ServiceAccount) and then
# the operator. Then kiali_cr_cleanup runs on each cluster.
resource "terraform_data" "kiali_app_cleanup" {
  count = local.kiali_enabled && local.addon_gitops ? 1 : 0

  input = {
    token_script     = local.token_script
    hub_api_url      = local.hub_api_url
    hub_admin_pass   = local.hub_admin_pass
    kubeconfig_path  = local.kubeconfig
    hub_context      = local.hub_cluster_key
    gitops_namespace = local.gitops_namespace
    app_names        = "hub-kiali spoke-kiali-appset hub-kiali-remote-secret-appset"
    appset_names     = "spoke-kiali hub-kiali-remote-secret"
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
  # root still renders the apps, and its self-heal would recreate them. create_before_destroy
  # reverses that order, so the app-of-apps update comes first. (terraform_data is replaced only
  # through triggers_replace, which these do not use, so nothing else changes.)
  lifecycle {
    create_before_destroy = true
  }

  depends_on = [terraform_data.kiali_cr_cleanup]
}

check "kiali_without_observability" {
  assert {
    condition     = !local.kiali_enabled || local.acm_observability_enabled
    error_message = "kiali_multicluster is on without acm_observability: Kiali shows clusters, workloads and config, but its graph and metrics stay empty."
  }
}
