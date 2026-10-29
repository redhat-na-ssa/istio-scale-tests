# ROSA HCP clusters (Terraform)

Creates N independent [ROSA with hosted control planes](https://docs.redhat.com/en/documentation/red_hat_openshift_service_on_aws/4/html/install_clusters/rosa-hcp-sts-creating-a-cluster-quickly)
clusters with the [`terraform-redhat/rosa-hcp/rhcs`](https://registry.terraform.io/modules/terraform-redhat/rosa-hcp/rhcs/latest)
module. Each cluster gets its own VPC, OIDC config, and account/operator roles. Cluster 1
becomes the ACM hub, and the rest become mesh members (see `terraform/platform`).

## One-time account setup

1. **AWS credentials:** an IAM user with AdministratorAccess, in a named profile
   (`aws configure --profile <name>`, then `export AWS_PROFILE=<name>`). `rosa` rejects root keys.
2. **Enable ROSA and link billing:** AWS console → Red Hat OpenShift Service on AWS → Get started.
   Enable ROSA, then **Continue to Red Hat** and sign in with the Red Hat account you'll use below.
   An AWS account's ROSA subscription links to only one Red Hat account, and sandbox accounts are
   often pre-linked to someone else's. In that case, use a different AWS account.
3. **Log in and create the link roles:**
   ```bash
   rosa login --use-auth-code      # use a private browser window to pick the right Red Hat account
   rosa create ocm-role --mode auto --yes
   rosa create user-role --mode auto --yes
   ```

## Run

```bash
cp terraform.tfvars.example terraform.tfvars   # region, openshift_version, cluster_count, sizing
./scripts/001-preflight.sh                     # read-only; prints the fix for anything missing
export RHCS_CLIENT_ID=ocm-cli RHCS_TOKEN="$(rosa token --refresh)"
terraform init
terraform plan -out=rosa.tfplan
terraform apply rosa.tfplan
mkdir -p ~/.rosa-window && terraform output -json by_cluster > ~/.rosa-window/by_cluster.json
```

Clusters take about 20 minutes. Outputs: `terraform output by_cluster` (API and console URLs, OCM
cluster ids, VPC ids, region), `terraform output cluster_admin_login` (sensitive), and a merged
kubeconfig at `./kubeconfig` (mode 0600). Save `by_cluster` right after apply, as above: the
teardown scripts read the VPC ids from that copy once a partial destroy has emptied the output.
Next, apply `terraform/platform` with `cluster_provider = "rosa"`.

Sizing: workers default to m7i.xlarge with 2 nodes (the ROSA minimum). Use `cluster_overrides` for
a bigger hub (for example m5.2xlarge), and `cluster_defaults.worker_autoscale_{min,max}` for
autoscaling; min = max gives a fixed pool, which caps EC2 spend. Prices and sized tiers (checked
2026-10-13) are in [the ROSA window plan](../../docs/runbooks/rosa-validation/window-plan.md#2-prices).
`service_quotas.tf` raises the VPC/EIP/NAT/IAM quotas the clusters need. It does not manage
the On-Demand Standard vCPU quota: the 21-cluster run needed 4000 vCPUs (request it by hand), plus
22 each of Elastic IPs, NAT gateways per AZ, gateway VPC endpoints, internet gateways and VPCs. Set
`manage_service_quotas = false` if your org blocks quota changes. `001-preflight.sh` runs
`rosa verify quota`, which wants at least 100 of those vCPUs (and 20 Classic LBs): a vCPU quota
held lower on purpose, as the window plan does, fails that one check.

## ACM Observability bucket (optional)

The OpenShift add-on `acm_observability` of `terraform/platform` keeps ACM Observability's
metrics (Thanos) in object storage. On ROSA, this root creates that storage. `<hub>` below is
cluster 1 (the first cluster key), the ACM hub; the bucket prefix allows 28 characters for it.

- `acm_observability_bucket = true`: an S3 bucket `<hub>-acm-obs-<suffix>` (public access
  blocked, SSE-S3, `force_destroy`), an IAM policy `<hub>-acm-obs-s3` that only lists the bucket
  and reads, writes and deletes its objects, and an IAM role `<hub>-acm-obs-s3` with that policy.
  The Thanos ServiceAccounts (`open-cluster-management-observability/observability-thanos-*`)
  assume the role through the hub's OIDC provider (STS), so no key is stored anywhere.
- `acm_observability_bucket_static_key = true` (needs the first): also an IAM user
  `<hub>-acm-obs-s3` with the same policy and an access key, which `terraform/platform` then puts
  in `thanos.yaml` instead of using the role. A fallback for when the Thanos pods get no web
  identity; the key is stored in this root's state.

Outputs: `acm_observability_storage` (bucket, region, endpoint, role ARN, and `auth`: `sts` or
`static`) and the sensitive `acm_observability_storage_credentials` (the static key, or null).
`terraform/platform` reads both from this root's state.

Apply this root with `acm_observability_bucket = true` first, then `terraform/platform` with
`acm_observability.enabled = true` (see
[OpenShift add-ons](../platform/README.md#openshift-add-ons-acm-observability-and-kiali)). Turn the
add-on off in the platform before you turn the bucket off here.

Destroy the platform first, as always: it deletes the MultiClusterObservability and waits until it
is gone. `terraform destroy` here then deletes the bucket with everything in it (`force_destroy`),
the role, the policy and the user. `003-auto-teardown.sh` removes the role with the clusters in its
first step (the role depends on the hub's OIDC provider) and the rest in the full destroy; its audit
reports a LEAK if a bucket `<hub>-acm-obs-*` or a role, user or policy `<hub>-acm-obs-s3` is left.

## Tear down

Clusters bill hourly. Destroy the platform first, then:

```bash
./scripts/002-pre-destroy-vpc-cleanup.sh --by-cluster-json ~/.rosa-window/by_cluster.json --dry-run
./scripts/002-pre-destroy-vpc-cleanup.sh --by-cluster-json ~/.rosa-window/by_cluster.json   # orphan LBs, ENIs, SGs
terraform destroy
```

002 merges the VPC ids from the saved copy, `terraform output` and the state, so it still finds
the VPCs after the output is gone. If `terraform destroy` fails on a VPC with `DependencyViolation`,
ROSA left its `<cluster-id>-vpce-private-router` security group or interface endpoint behind. Once
the clusters are gone, run 002 again with `--delete-interface-endpoints` (it deletes only endpoints
Terraform does not manage, and only in a VPC with no instances left), then `terraform destroy` again.

**Billing-first auto-teardown.** `./scripts/003-auto-teardown.sh` tears everything down
unattended: `terraform destroy -target=module.rosa_hcp` first (the clusters, their worker pools and
IAM roles, where the hourly charges are), then 002 with `--delete-interface-endpoints` (and the
saved VPC list once it exists), then the full destroy, retrying each step, then a read-only audit.
It refreshes the OCM token itself (`rosa token --refresh`), logs to `~/.rosa-window/teardown.log`,
exits 1 if anything still bills, and publishes the result to an SNS topic (`--sns-topic-arn`).
It never touches `terraform/platform`.

```bash
./scripts/003-auto-teardown.sh --dry-run --sns-topic-arn <arn>   # what the unattended run needs, and the plan
date -u +%s > ~/.rosa-window/t0                           # T0, when apply starts
./scripts/003-auto-teardown.sh --arm --fire-after 8h15m --sns-topic-arn <arn>   # systemd user timer: monotonic + absolute UTC trigger
./scripts/003-auto-teardown.sh --disarm                   # after a clean manual teardown and audit
./scripts/003-auto-teardown.sh --now                      # tear down now (nothing is destroyed without --now)
```

`--arm` needs systemd user units with linger (`loginctl enable-linger`; on WSL, systemd enabled and
`[general] instanceIdleTimeout=-1` in `%UserProfile%\.wslconfig`, since systemd units do not keep a
WSL distro running) and passes the current `PATH`, `AWS_PROFILE` and `AWS_REGION` to the unit. It
also needs `--sns-topic-arn` with a confirmed email subscription, the alert that reaches an operator
away from the host, and publishes an "armed" message there. A reboot drops the timer: arm again (it
recomputes the deadline from T0). `8h15m` is the default and the window plan's Tier C deadline
(Tier B passes `7h15m`). The cost-capped window that uses all this is in
[docs/runbooks/rosa-validation](../../docs/runbooks/rosa-validation/README.md).

This root uses only the default workspace (`terraform/platform` reads `terraform.tfstate` here by
path). Never export `TF_WORKSPACE` for the platform's `rosa` workspace: here it names an empty
workspace, where `terraform destroy` reports success and destroys nothing. Scripts 002 and 003
ignore it.

Keep `terraform.tfvars`, state, and `kubeconfig` out of git (they're already in `.gitignore`).
