---
leave-behind: v1
state-scope: rosa-validation
status: current
---

# ROSA validation leave-behind

How to stand up the ROSA path end to end (`terraform/rosa-hcp`, then `terraform/platform` in rosa
mode, then a mesh check), run one cost-capped validation window on it, and tear it all down again.
**No ROSA clusters exist.** The 2026-10-29b build (T0 16:59 UTC): the same functional mesh
rebuilt to validate the ACM Observability and multicluster Kiali add-ons, applied from a clean
demo worktree (detached at `81169f9`) with `acm_observability`, `kiali_multicluster`, the S3
bucket and the full-telemetry override on (Verify and recover, "Kiali and ACM Observability").
Validated live the same day, traffic graph included, plus Kiali's Travels demo spread over the
three members. Torn down at the owner's request with `003-auto-teardown.sh --now` from that
worktree (started 19:17 UTC, `CLEAN` 20:09; the new bucket and IAM audit checks passed) and
audited empty across all regions; its platform `rosa` workspace was discarded and the demo
worktree removed. About $15 (an estimate: about 2 h 40 min at $5.5/h). Its window files are in
`~/.rosa-window/2026-10-29b/` (`status.md`, `p9-audit.txt`).
Earlier that day, the first build: the 2026-10-29 OSSM functional mesh (hub `cluster-001` plus members
`cluster-002` to `cluster-004` at the small functional sizing, Re-run "Functional run"; T0 13:05
UTC; applied from the session worktree `<repo>/.claude/worktrees/rosa-cluster-mesh-provision-8991bc`
at `14218c4`, the first commit of the repo's new home `redhat-na-ssa/istio-scale-tests`; no
auto-teardown armed, by the owner's choice) was torn down at the owner's request with
`003-auto-teardown.sh --now` from a clean teardown worktree (`CLEAN` 15:35 UTC, 24 min) and audited
empty across all regions the same day; its platform `rosa` workspace was discarded. About $14 (an
estimate: about 2 h 25 min at $5.5/h). It is to be rebuilt the same way to validate the Kiali and ACM
Observability add-on (`docs/design/kiali-acm-multicluster.md`); the tfvars stay in that worktree.
Its window files are in `~/.rosa-window/2026-10-29/` (`status.md`, `p9-audit.txt`). October's
month-to-date spend before it was $230.44, already above the `rosa-window-monthly` budget's $210,
so that budget's ACTUAL alerts had fired and warned no more that month.
Before it, the 2026-10-27 campaign run (hub + 5 members, 6 clusters, the
campaign runner's `rosa` profile, T0 12:16 UTC; record
[`docs/campaigns/2026-10-27-rosa-hcp-5-member/`](../../campaigns/2026-10-27-rosa-hcp-5-member/README.md))
was torn down with `003-auto-teardown.sh --now` chained after the last suite (`CLEAN` 20:13 UTC),
destroyed and audited empty across all regions on 2026-10-27; its timers are disarmed, its
platform `rosa` workspace discarded, and its window files moved to `~/.rosa-window/2026-10-27/`.
Before it, the 2026-10-16 window (Tier C, 4 clusters, window commit `12401a8`,
T0 17:59 UTC; it validated BACKLOG section 9) was torn down with `003-auto-teardown.sh --now`
from 21:03 UTC (`CLEAN` 21:27) and audited empty across all regions the same day; about $30-35
(an estimate until Cost Explorer confirms it). Its timers are disarmed and its platform `rosa`
workspace was discarded. The 2026-10-14 window (Tier C, window commit `8150d4b`, T0 12:42 UTC,
`CLEAN` 22:01) billed $94.62 in Cost Explorer ($79.21 on 2026-10-14 and $15.41 posted on
2026-10-15), against its $82 estimate. Left on purpose: the free SNS topic `rosa-window` and the
`rosa-window-monthly` budget, raised from $100 to $210 for the second window (October was at
$105 before it). Open: Cost Explorer for 2026-10-16 and 2026-10-17, `rosa-residual-daily`, and an
off-laptop copy of both windows' results (destination is the owner's choice). The run
before it (3 HCP clusters, ~1h50m, 2026-10-12) was destroyed and verified empty. The account-level
ROSA setup stays between windows (the OCM role, the user role and the
`ManagedOpenShift-HCP-ROSA-*` account roles). The window is planned in
[window-plan.md](window-plan.md); its owner decisions were settled on 2026-10-13: Tier C and a $100
hard cap. While a window runs, this paragraph says "4 clusters exist since <T0>, auto-teardown armed
for <T0+8:15>" (or, for a functional run, "no auto-teardown armed"); afterwards, "destroyed and
audited empty on <date>".

## Operability

### State and access

- AWS: an IAM user with AdministratorAccess (never root keys, which `rosa` rejects) in a
  named AWS CLI profile in `~/.aws/`. Export `AWS_PROFILE=<profile>` and `AWS_REGION=<region>`
  for every terraform, rosa and aws command.
- Red Hat: `rosa login --use-auth-code` (session in `~/.config/ocm/ocm.json`).
  Terraform's rhcs provider reuses it through
  `RHCS_CLIENT_ID=ocm-cli RHCS_TOKEN="$(rosa token --refresh)"` (the offline refresh token; the
  provider mints access tokens from it). The auto-teardown runs that itself, so the login must stay
  valid all window: check `rosa whoami` at every checkpoint. It expires between windows (it had on
  2026-10-29): log in again before any plan or destroy.
- One-time account setup: in the AWS console, open Red Hat OpenShift Service on AWS → Get started,
  enable ROSA, then "Continue to Red Hat" and sign in as the Red Hat account `rosa` uses. Then
  `rosa create ocm-role --mode auto --yes` and `rosa create user-role --mode auto --yes`.
  An AWS account's ROSA subscription can be linked to only one Red Hat account,
  and demo-platform sandbox accounts usually come pre-linked to someone else.
- Old ROSA classic IAM: on 2026-10-14 the 4 classic account roles, 18 orphaned classic operator
  roles from earlier clusters and their 10 customer-managed policies were deleted. Only the HCP
  account roles, the OCM role and the user role remain. The deleted roles' trust policies and policy
  documents are saved in `~/.rosa-window/iam-backup/` on the operator host.
- Window worktree: run a window from its own worktree at the pinned commit, never by detaching the
  main checkout. The 2026-10-14 window runs from `<repo>-rosa-window`, detached at
  `8150d4b` (`git -C <repo> worktree add <path> <window-sha>`). The main checkout's
  `terraform/platform` default workspace holds the existing-cluster lab; the window worktree has
  no lab state, so no ROSA command there can touch the lab. Since 2026-10-28 the repo lives at
  `redhat-na-ssa/istio-scale-tests` with a fresh history (first commit `14218c4`); the old window
  commits are not in it.
- The 2026-10-29 run (OSSM functional mesh; destroyed and audited empty the same day):
  - Worktree: `<repo>/.claude/worktrees/rosa-cluster-mesh-provision-8991bc` (branch
    `claude/rosa-cluster-mesh-provision-8991bc`). Its Terraform state and kubeconfig are
    gitignored, so the worktree looks clean to git: while clusters exist, do not remove or archive
    it before the teardown audit is empty. Its `terraform.tfvars` and `rosa.tfvars` are kept there
    for the rebuild.
  - Teardown from a clean checkout when the run's worktree has Terraform edits in progress (on
    2026-10-29 the Kiali add-on was being built in it): `git -C <repo> worktree add --detach <dir>
    <last-applied-commit>`, move `terraform/rosa-hcp/{terraform.tfstate,terraform.tfstate.backup,kubeconfig}`
    and `terraform/platform/terraform.tfstate.d/rosa/` there, copy both tfvars and `.terraform/`,
    `terraform init` both roots, run `003-auto-teardown.sh --dry-run` and then `--now` from it,
    discard its platform `rosa` workspace, and remove it once the audit is empty. A destroy reads
    the configuration as well as the state, so half-edited `.tf` files can fail it midway.
  - State backups taken after each apply: `~/.rosa-window/2026-10-29/rosa-hcp.tfstate.backup`
    (and `platform-rosa.tfstate.backup` once the platform is applied), mode 0600. If the worktree
    is lost, restore them into a fresh worktree at `14218c4` as `terraform/rosa-hcp/terraform.tfstate`
    and `terraform/platform/terraform.tfstate.d/rosa/terraform.tfstate`, with the tfvars below.
  - `~/.rosa-window/by_cluster.json` is this run's saved copy (the default path of scripts 002 and
    003); `~/.rosa-window/2026-10-29/by_cluster.json` is the same copy.
  - No `rosa-autoteardown` or `rosa-warn` timer, and no phone alarms: the owner tears down by hand.
- The 2026-10-29b run (Kiali and ACM Observability validation; destroyed and audited empty the
  same day, its worktree and credentials file removed; kept as the procedure for the next one):
  - Worktree: `<home>/istio-scale-tests-demo-20261029`, detached at the branch commit Argo CD
    pins (`gitops_app_repo_revision`). It holds the state, the kubeconfig and the validated
    tfvars; move it to a new commit with `git -C <it> checkout --detach <sha>` plus the same
    revision in `rosa.tfvars`, never by editing files there. Remove it only after the audit.
  - State backups: `~/.rosa-window/2026-10-29b/{rosa-hcp,platform-rosa}.tfstate.backup` (0600).
  - Logins: `cluster-admin` on every cluster, in `~/rosa-demo-credentials.txt` (0600, with the
    Kiali and console URLs); the password comes from
    `terraform -chdir=<worktree>/terraform/rosa-hcp output -raw cluster_admin_password`.
  - The echo app was applied by hand from `charts/mesh-verify-appset.yaml` (filled from
    `hub-gitops-root`, pinned to `471216b`); traffic came from a local curl loop through
    `cluster-002`'s ingress (`~/.rosa-window/2026-10-29b/traffic.log`), which stops with the
    session that started it.
- Terraform state, in the window worktree: `terraform/rosa-hcp/terraform.tfstate` and the
  platform's `rosa` workspace (`terraform/platform/terraform.tfstate.d/rosa/`), both local and
  gitignored. rosa-hcp uses only its default workspace (the platform reads
  `../rosa-hcp/terraform.tfstate` by path). Every platform command is prefixed with
  `TF_WORKSPACE=rosa`, never exported (Re-run). Inputs in `terraform.tfvars` / `rosa.tfvars`
  (gitignored, mode 0600, in the window worktree).
- Cluster access: `terraform/rosa-hcp/kubeconfig` (mode 0600; exec plugin that logs in as
  `cluster-admin` with the Terraform-generated password). Its contexts are the cluster keys:
  `cluster-001` is the ACM hub (`<acm-hub-ctx>`), `cluster-002` to `cluster-004` are
  `<mesh-a-ctx>`, `<mesh-b-ctx>`, `<mesh-c-ctx>`. The password itself is only in the state
  (`terraform -chdir=terraform/rosa-hcp output cluster_admin_login`, sensitive).
- Planned window: Tier C, owner-approved on 2026-10-13.
  - Hub on 2× m5.2xlarge, `<mesh-a-ctx>` on 3× r7i.2xlarge, and `<mesh-b-ctx>` and
    `<mesh-c-ctx>` on 3× m7i.xlarge, all with fixed worker counts, in us-east-2.
  - Quotas: On-Demand Standard vCPUs (`L-1216C47A`) at least 64, Classic LBs at least 10, and the
    VPC, internet gateway, Elastic IP and NAT quotas from `terraform/rosa-hcp/service_quotas.tf`.
    On 2026-10-14 the account already had all of them (vCPU quota 1848, Classic LBs 20, VPCs,
    internet gateways and EIPs 10), so no increase was requested and `rosa verify quota` passed
    outright. A quota that high caps nothing: the fixed worker pools are the only structural cap.
    An account held at 64-72 vCPUs instead fails that one `rosa verify quota` check by design
    (window-plan.md, P0).
  - Tiers B and A are the fallbacks (window-plan.md, Fallback tiers).
- Budgets:
  - `rosa-window-monthly`: $100 limit (the owner's hard cap; nothing else bills in the account),
    ACTUAL alerts at 50/80/100% and a FORECASTED alert at 100%; raised to $210 for the second
    window. An older account-wide $100 budget (`Personal`) exists alongside it and is left alone.
  - `rosa-residual-daily`: the post-window leak tripwire, created at T+1.
- Alerts that reach the operator away from the host, both required for a window (a functional run
  without a timer uses neither):
  - SNS topic `rosa-window` (us-east-2) with a confirmed email subscription; its ARN is in
    `~/.rosa-window/sns-topic-arn`. It gets an "armed" email at T0 and the auto-teardown's result;
    `003-auto-teardown.sh --arm` refuses without it.
  - Phone alarms at T0+7:15, T0+7:45 and T0+9:15. The last is the off-host check that the
    auto-teardown worked, and the only alert left if the operator host dies.
- Window files outside git, in `~/.rosa-window/<date>/` per run since 2026-10-29 (older runs'
  files were moved into `2026-10-14/`, `2026-10-16/` and `2026-10-27/`): `t0` (epoch seconds when
  apply started), `by_cluster.json` (saved `terraform output -json by_cluster`: the VPC and cluster
  ids that outlive the state; the live run's copy also sits at `~/.rosa-window/by_cluster.json`,
  where 002 and 003 look by default), `teardown.log` and `teardown.result` (written by the
  auto-teardown, in `~/.rosa-window/`), `status.md` (phase progress and checkpoint times, for a
  resumed session), `window-sha`, the phase logs (`p0-*.log`, `p0-dryruns/`, `p1-*.log` to `p9-*`,
  `x*.log`), `x-runs.sh` and `gw-extension.tfvars` (the 2026-10-14 extensions), `p9-audit.txt`, and
  the results archive `results-<date>-rosa-window.tar.gz`. Shared across runs, in `~/.rosa-window/`:
  `sns-topic-arn`, `budget.json`, `notify.json`, `iam-backup/`, and the helper scripts in `bin/`.
- systemd user units on the operator host: `rosa-autoteardown` (armed by
  `terraform/rosa-hcp/scripts/003-auto-teardown.sh --arm`; log in `journalctl --user -u rosa-autoteardown`
  and `teardown.log`) and `rosa-warn`. The tfstate is local, so the backstop lives on the same host.
  On WSL, systemd units do not keep the distro running: it stops about 15 s after the last terminal
  closes, and the timers with it, unless `%UserProfile%\.wslconfig` sets
  `[general] instanceIdleTimeout=-1` (window-plan.md, P0). The operator host has it since
  2026-10-14.
- Task 3's GitOps pause records (`tests/dataplane/results/rosa-lb/gitops-pause-ew.json`, and
  `gitops-pause-ingress.json` for an ingress experiment; gitignored) exist only while a pause is
  held; release with `tests/tuning/006-gitops-pause.sh --resume --state-file <it>`. Both were
  released on 2026-10-14.

### Template map

terraform/rosa-hcp/terraform.tfvars.example -> terraform/rosa-hcp/terraform.tfvars (region, version, cluster_count 4, fixed worker counts, hub and cluster-002 r7i.2xlarge overrides, common_tags; the 2026-10-29 functional run: members 2x m7i.xlarge, hub 2x m5.2xlarge, all fixed at 2, purpose = "ossm-functional")
terraform/rosa-hcp/outputs.tf (local.kubeconfig_yaml) -> terraform/rosa-hcp/kubeconfig (merged kubeconfig, mode 0600)
terraform/rosa-hcp/outputs.tf (output by_cluster) -> ~/.rosa-window/by_cluster.json (VPC and cluster ids read by scripts 002 and 003 after the state is gone; also copied to ~/.rosa-window/<date>/by_cluster.json)
terraform/platform/terraform.tfvars.example -> terraform/platform/rosa.tfvars (cluster_provider = "rosa", repo URL and pinned revision, istiod 2 CPU/8Gi request and 4 CPU/16Gi limit, proxy 20m/64Mi requests, small Argo CD; the 2026-10-29 functional run: repo https://github.com/redhat-na-ssa/istio-scale-tests.git at 14218c4, istiod 1 replica 500m/2Gi request and 2 CPU/4Gi limit)
terraform/platform/terraform.tfvars.example (OpenShift add-ons block) -> terraform/platform/rosa.tfvars (2026-10-29b, validated: acm_observability = { enabled = true }, kiali_multicluster = { enabled = true }, and under "spoke-ossm-appset" tuningBaseline = { telemetryFiltering = { enabled = false }, accessLogFiltering = { enabled = false } } for full telemetry)
terraform/rosa-hcp/terraform.tfvars.example (acm_observability_bucket) -> terraform/rosa-hcp/terraform.tfvars (2026-10-29b: acm_observability_bucket = true, the S3 bucket and the STS role)
terraform/rosa-hcp/terraform.tfstate -> ~/.rosa-window/2026-10-29/rosa-hcp.tfstate.backup (copy after the apply, in case the session worktree is removed)
terraform/platform/terraform.tfstate.d/rosa/terraform.tfstate -> ~/.rosa-window/2026-10-29/platform-rosa.tfstate.backup (copy after the platform apply)
tests/<suite>/configs/smoke.env -> tests/<suite>/configs/rosa-*.local.env (gitignored run configs with the real contexts)

### Re-run

The day before (no cluster spend): the fallback checks, quotas, budgets, tfvars and dry runs in
[window-plan.md, Prerequisites](window-plan.md#4-prerequisites-p0-the-day-before-no-cluster-spend).
Then, from the window worktree (timers for Tier C; the fallback tiers use other offsets, see
window-plan.md, Fallback tiers):

```bash
export AWS_PROFILE=<profile> AWS_REGION=us-east-2
unset TF_WORKSPACE                                   # never exported: rosa-hcp has only the default workspace
terraform/rosa-hcp/scripts/001-preflight.sh          # read-only; prints the fix for each failed check
# With the vCPU quota held at 64-72 (P0), 001's quota check FAILs by design (rosa wants 100).
# Then this must print nothing: no quota flagged but the vCPU one, no error.
rosa verify quota --region us-east-2 2>&1 |
  grep -vE '^(INFO|WARN): |L-1216C47A|Insufficient AWS quotas|following service quota codes'
terraform/rosa-hcp/scripts/003-auto-teardown.sh --dry-run --sns-topic-arn <arn>   # the unattended teardown would work

# T0: start the clock and arm the backstop before anything bills
mkdir -p ~/.rosa-window && date -u +%s > ~/.rosa-window/t0
terraform/rosa-hcp/scripts/003-auto-teardown.sh --arm --fire-after 8h15m --sns-topic-arn <arn>   # Tier B: 7h15m
systemd-run --user --unit=rosa-warn \
  --on-calendar="$(date -u -d "@$(( $(cat ~/.rosa-window/t0) + 26100 ))" '+%Y-%m-%d %H:%M:%S UTC')" \
  -- notify-send -u critical "ROSA: teardown must start in 30 min"                  # T0+7:15; Tier B: 22500
systemctl --user list-timers | grep rosa                             # both armed
# On the phone: the SNS email "ROSA auto-teardown armed: fires at ..." has arrived, and alarms are
# set for T0+7:15, T0+7:45 and T0+9:15 (Tier B: 6:15, 6:45, 8:15).

export RHCS_CLIENT_ID=ocm-cli RHCS_TOKEN="$(rosa token --refresh)"
terraform -chdir=terraform/rosa-hcp init
terraform -chdir=terraform/rosa-hcp plan -out=rosa.tfplan && terraform -chdir=terraform/rosa-hcp apply rosa.tfplan
terraform -chdir=terraform/rosa-hcp output -json by_cluster > ~/.rosa-window/by_cluster.json   # the VPC ids for 002/003
terraform -chdir=terraform/platform init
terraform -chdir=terraform/platform workspace new rosa               # first time in this worktree
TF_WORKSPACE=rosa terraform -chdir=terraform/platform plan -var-file=rosa.tfvars -out=platform.tfplan
TF_WORKSPACE=rosa terraform -chdir=terraform/platform apply platform.tfplan
```

`TF_WORKSPACE=rosa` goes in front of each platform command, never into `export`: exported, it
also reaches the rosa-hcp commands later in the same shell, and there it names an empty workspace in
which `destroy` prints `Destroy complete! Resources: 0 destroyed.` and exits 0 while every cluster
keeps billing. Scripts 002 and 003 ignore it; a plain `terraform -chdir=terraform/rosa-hcp` does not.

`--arm` reads T0 from `~/.rosa-window/t0` and sets two triggers on the same instant: a monotonic
one, and an absolute UTC time that still fires after the laptop wakes. It refuses to arm when the
unattended run would fail (tools on PATH, AWS credentials, rosa login, and on WSL a
`%UserProfile%\.wslconfig` without `instanceIdleTimeout=-1`) or could fail unnoticed (no
`--sns-topic-arn`, or a topic with no confirmed subscription). Once armed it publishes an "armed"
email to the topic, which proves the alert path. Transient timers do not survive a reboot: after
one, run the same `--arm` command again (it recomputes from T0). Without `--arm` that command fails
rather than tearing down: a real teardown needs `--now`.

Sizing (prices checked 2026-10-13, sources in [window-plan.md](window-plan.md#2-prices)):

- Every tier puts the hub on 2× m5.2xlarge and the members on 3 fixed workers
  (`worker_autoscale_min = worker_autoscale_max = 3`).
- Tier C, the plan of record, gives `cluster-002` (`<mesh-a-ctx>`) 3× r7i.2xlarge through
  `cluster_overrides`, and b and c 3× m7i.xlarge. It costs $8.25/h and needs 64 vCPUs. Its plan is
  224 resources (2026-10-14).
- The fallbacks: Tier B (all members m7i.xlarge) is $6.75/h and needs 52; Tier A (2 members) is
  $5.12/h and needs 40.
- The `rosa.tfvars` override sets istiod to 1 replica with a 2 CPU / 8Gi request and a 4 CPU / 16Gi
  limit (an 8Gi limit on B and A). The chart default, 3 × 4 CPU / 16Gi requested, does not fit.
- The override sets the proxy requests to 20m / 64Mi.
- On b and c the 16Gi limit is nominal. On their 16 GiB nodes, an istiod above its 8Gi request is
  the first pod evicted under memory pressure (window-plan.md, "b and c under the 16Gi limit").

Functional run (the 2026-10-29 shape, for trying OSSM configuration rather than measuring scale):

- Same commands as above, minus the T0 block's `--arm`, `rosa-warn` and phone alarms; still write
  `t0` (to `~/.rosa-window/<date>/t0`) so the spend can be read off the clock.
- `terraform.tfvars`: `cluster_count = 4`; `cluster_defaults = { compute_machine_type = "m7i.xlarge", replicas = 2, worker_autoscale_min = 2, worker_autoscale_max = 2 }`;
  `cluster_overrides = { "cluster-001" = { compute_machine_type = "m5.2xlarge", replicas = 2, worker_autoscale_min = 2, worker_autoscale_max = 2 } }`.
  The plan is 224 resources, one `workers` pool of 2 nodes per cluster (the provider adopts the
  cluster's default pool), 8 nodes in all.
- `rosa.tfvars`: the small-hub `argocd_config_values`, and under `"spoke-ossm-appset"`
  `pilot = { replicaCount = 1, resources = { requests = { cpu = "500m", memory = "2Gi" }, limits = { cpu = "2", memory = "4Gi" } } }`
  plus `proxy = { resources = { requests = { cpu = "20m", memory = "64Mi" } } }`.
- About $5.5/h: hub $1.87/h, each member about $1.22/h (2 × $0.4055 nodes, $0.351 fixed, $0.06
  gateway LBs), plus a little NAT processing.
- Room on each member: the mesh adds about 0.9 vCPU / 3.5 GiB of requests and 7 pods, which leaves
  about 1 vCPU (docs' conservative ROSA baseline) to 4 vCPU (measured baseline) of requests for
  test apps. Too small for the repo's scale suites: their CPU preflight may refuse steps (raise the
  members to 3 workers, or set `SCALE_CPU_PREFLIGHT_ENFORCE=0`).
- After each apply, back up the state into `~/.rosa-window/<date>/` (Template map).

### Verify and recover

- `rosa list clusters`: all `ready`. `oc --kubeconfig terraform/rosa-hcp/kubeconfig --context cluster-001 get applications.argoproj.io -n openshift-gitops`: all Synced/Healthy.
- On each member, `oc exec -n mesh-wiring-verify deploy/mesh-wiring-verify -- sh /opt/check/readiness.sh`: `Ready ... members=<the three members> ca=shared`.
- On each member, istiod runs 1 pod with an 8Gi memory request and a 16Gi limit (8Gi on the
  fallback tiers; `2Gi/4Gi` on a functional run):
  `oc -n istio-system get pod -l app=istiod -o jsonpath='{..resources.requests.memory}/{..resources.limits.memory}'`.
- The mesh preflight, read-only plus an echo round trip from the hub:
  `KUBECONFIG=terraform/rosa-hcp/kubeconfig SETUP_CONTEXTS=cluster-002,cluster-003,cluster-004 tests/preflight/001-check-mesh.sh --hub-context cluster-001 --echo`.
- Kiali and ACM Observability (validated 2026-10-29b, Kiali 2.33.1, OSSM 3.4.4, ACM 2.17.3):
  - Order: apply rosa-hcp with `acm_observability_bucket = true` (6 resources, no cluster change),
    then the platform with both add-ons (the add-on resources on the hub, the app-of-apps update);
    every Application was Synced/Healthy about 5 minutes later.
  - `oc --context cluster-001 get mco observability`: `Ready=True`; 34 pods Running in
    `open-cluster-management-observability`. Early on it reports `Failed=True ... grafana is not
    ready` for a minute or two; that clears.
  - Each member: pods Running in `openshift-user-workload-monitoring`.
  - Hub `istio-system`: the `kiali` pod Ready and three Secrets labelled `kiali.io/multiCluster=true`;
    the Kiali log shows `Discovered cluster ... Accessible=true` for each member and
    `Health refresh completed clusters=4 ... errors=0`.
  - `oc get oauthclient kiali-istio-system -o jsonpath='{.redirectURIs}'`: on each member
    `https://<hub-kiali-route>/api/auth/callback/<member>`, on the hub `.../api/auth/callback`.
  - Metrics: port-forward `svc/observability-thanos-query-frontend` 9090 on the hub and query
    `sum by (destination_cluster, reporter) (rate(istio_requests_total{destination_workload_namespace="mesh-verify"}[3m]))`:
    a series per member, with `reporter="source"` too when full telemetry is on; the newest sample
    is under about 70 s old at the 60 s interval.
  - UI: log in on the hub as `cluster-admin`, then to each member from Kiali's profile menu; the
    traffic graph of `mesh-verify` shows the ingress gateway on one member calling the echo app on
    all three. The API with a hub-only token answers 403 "namespace not accessible" for member
    namespaces: expected, it needs the per-member logins.
  - The kiali-ossm Subscription moved from v2.27.5 to v2.33.1 on its own (Automatic, `stable`), and
    the members got OSSM 3.4.4; the validation ran on that pair (BACKLOG, follow-ups).
- mesh-verify through each member's ingress (`.status.loadBalancer.ingress[0].hostname` on AWS): answers come from every member.
  Through Classic LBs this fails intermittently (BACKLOG 9.8); the platform now gives the ingress
  an NLB in rosa mode (`rosa_ingress_nlb`), while the east-west gateway stays on a Classic LB.
- Load balancer inventory (A0) and the task 3 commands: [window-plan.md, P2 and P5](window-plan.md#5-run-order-tier-c).
  After any gateway Service experiment, the recovery gate must pass: the GitOps pause resumed, every
  Application Synced/Healthy, the Service back to the chart spec, `ca=shared` on all 3 gates, a probe
  from every source REACHABLE, and exactly 2 gateway LBs per member.
- More than about 500 Terminating namespaces on any member, a missed T0+7:45 (T0+6:45 on Tier B)
  or a lost mesh: go straight to the billing-first teardown below.
- Teardown, planned path (results backed up first):

```bash
export AWS_PROFILE=<profile> AWS_REGION=us-east-2 RHCS_CLIENT_ID=ocm-cli RHCS_TOKEN="$(rosa token --refresh)"
unset TF_WORKSPACE                     # else the rosa-hcp destroy below "succeeds" on an empty workspace
TF_WORKSPACE=rosa terraform -chdir=terraform/platform destroy -var-file=rosa.tfvars   # time box: 15 min
terraform/rosa-hcp/scripts/002-pre-destroy-vpc-cleanup.sh --by-cluster-json ~/.rosa-window/by_cluster.json
terraform -chdir=terraform/rosa-hcp destroy
# DependencyViolation on a VPC: ROSA left its <cluster-id>-vpce-private-router security group or its
# interface endpoint behind. Once the clusters are gone, run 002 again with
# --delete-interface-endpoints, then terraform destroy again.
```

  Keep both timers armed until the audit below comes back empty, then disarm them:
  `terraform/rosa-hcp/scripts/003-auto-teardown.sh --disarm; systemctl --user stop rosa-warn.timer`.
  A destroy that silently did nothing then still meets the backstop.
- Functional run teardown (2026-10-29: no timer to fall back on, so finish with the audit). From the
  run's worktree, after `rosa login` if `rosa whoami` fails:
  `terraform/rosa-hcp/scripts/003-auto-teardown.sh --now` (it needs no SNS topic; pass
  `--sns-topic-arn "$(cat ~/.rosa-window/sns-topic-arn)"` for the result email), then discard the
  platform's `rosa` workspace as below, then the audit. Or the planned path above, which also
  removes the hub's Argo CD and ACM objects first (they bill nothing once the clusters are gone).
- Teardown, billing-first (the platform destroy hangs past its 15 minutes, or any abort rule fires):
  run `terraform/rosa-hcp/scripts/003-auto-teardown.sh --now` by hand; it is what the timer runs. It
  destroys `module.rosa_hcp` first (the clusters, their worker pools and IAM roles: the hourly
  ROSA, EC2 and EBS charges stop and nothing is left to recreate load balancers), then runs 002
  with `--delete-interface-endpoints` (and the saved VPC list, when there is one), then the full
  destroy, retrying steps up to 3 times, then a read-only audit. It ignores an exported
  `TF_WORKSPACE`, logs to `~/.rosa-window/teardown.log`, writes `teardown.result`, exits 1 on
  anything left, and publishes the result to `--sns-topic-arn`. It never touches
  `terraform/platform`; afterwards discard that state, which bills nothing, in the window worktree
  only: `unset TF_WORKSPACE; terraform -chdir=terraform/platform workspace select default && terraform -chdir=terraform/platform workspace delete -force rosa`.
- When the T0+9:15 phone alarm rings (T0+8:15 on Tier B), unless a teardown's audit already came
  back empty, confirm that the auto-teardown worked
  ([window-plan.md, If the T0+9:15 alarm rings](window-plan.md#if-the-t0915-alarm-rings)). An SNS
  email "finished: clean" settles it. Otherwise, on the operator host, in a shell set up as in
  Re-run (`cd <window-worktree>`, `export AWS_PROFILE=<profile> AWS_REGION=us-east-2`, and the
  `RHCS_*` variables), since it may be a fresh one after a reboot:
  - `systemctl --user is-active rosa-autoteardown.service` says `active`: it is still running;
    follow `~/.rosa-window/teardown.log`.
  - `~/.rosa-window/teardown.result` says `CLEAN`: only the email failed; run the audit.
  - Anything else: `terraform/rosa-hcp/scripts/003-auto-teardown.sh --now`, by T0+10:30 at the
    latest to stay under $100.
  - Host dead: `rosa delete cluster --cluster <name> --yes` per window cluster, from a machine
    with `rosa login` and credentials for the window's AWS account (`rosa` finds a cluster only
    through that account); without such a machine, delete each cluster in OpenShift Cluster
    Manager (console.redhat.com/openshift: Options or Actions, Delete cluster). Once the host is
    back, wait for those deletions to finish before `003 --now`.
- Lost worktree (the state is gone with it): restore the state backups as in State and access,
  then tear down as above. Without them, `rosa delete cluster --cluster <name> --yes` per cluster,
  then 002 with `--by-cluster-json ~/.rosa-window/by_cluster.json --delete-interface-endpoints`
  once the clusters are gone, then delete the VPCs and the IAM roles and OIDC configs named after
  the clusters by hand, and run the audit.
- Audit after any teardown; every check must come back empty, except one pre-existing public
  hosted zone in the account that is not the window's (any other zone is a leftover). The script's audit covers the state,
  the window's clusters, the saved VPCs and new unattached volumes; this list, across regions, is
  the authority (tag filters miss resources the clusters created with their own tags):

```bash
unset TF_WORKSPACE                     # else 'state list' reads an empty workspace and looks clean
rosa list clusters                                                  # none of the window's clusters
terraform -chdir=terraform/rosa-hcp state list                      # nothing
ls terraform/rosa-hcp/terraform.tfstate.d 2>/dev/null               # nothing: rosa-hcp has no other workspace
for id in $(jq -r '.[].vpc_id' ~/.rosa-window/by_cluster.json); do
  aws ec2 describe-vpcs --vpc-ids "$id" 2>&1 | grep -q InvalidVpcID.NotFound || echo "VPC $id still exists"
done
for r in $(aws ec2 describe-regions --query 'Regions[].RegionName' --output text); do
  echo "== $r"
  aws --region "$r" ec2 describe-instances --filters Name=instance-state-name,Values=pending,running,stopping,stopped --query 'Reservations[].Instances[].InstanceId'
  aws --region "$r" ec2 describe-nat-gateways --filter Name=state,Values=pending,available,deleting --query 'NatGateways[].NatGatewayId'
  aws --region "$r" elb describe-load-balancers --query 'LoadBalancerDescriptions[].LoadBalancerName'
  aws --region "$r" elbv2 describe-load-balancers --query 'LoadBalancers[].LoadBalancerArn'
  aws --region "$r" ec2 describe-addresses --query 'Addresses[].PublicIp'
done
aws ec2 describe-volumes --query 'Volumes[].[VolumeId,State,CreateTime]'
aws ec2 describe-vpc-endpoints --query 'VpcEndpoints[].[VpcEndpointId,VpcId,State]'
aws ec2 describe-snapshots --owner-ids self --query 'Snapshots[].[SnapshotId,StartTime]'
aws route53 list-hosted-zones --query 'HostedZones[].Name'
aws secretsmanager list-secrets --query 'SecretList[].Name'
aws resourcegroupstaggingapi get-resources --tag-filters Key=purpose,Values=rosa-window
aws resourcegroupstaggingapi get-resources --tag-filters Key=purpose,Values=ossm-functional   # the 2026-10-29 run's tag
```

- At T+1 and T+2 days: Cost Explorer by service
  (`aws ce get-cost-and-usage --time-period Start=<day>,End=<next-day> --granularity DAILY --metrics UnblendedCost --group-by Type=DIMENSION,Key=SERVICE`,
  $0.01 per call) shows EC2, ELB, VPC, EBS and the Marketplace ROSA line at about $0. Create
  `rosa-residual-daily` ($3, ACTUAL > 100%) at T+1: created earlier it fires on the window day itself
  and on ROSA charges that post late.

## Decision log

### Decisions

- Purpose: prove the ROSA path (greenfield: Terraform installs ACM, GitOps and the mesh), which the
  existing-cluster lab (brownfield) cannot, and measure what only AWS can show (task 3's load
  balancers, the 3-member partial mesh, AWS cross-cluster latency). Both paths were verified on 2026-10-12.
- Account traps found live, all now caught by `001-preflight.sh`: expired keys, root keys,
  no OCM role or user role, the AWS account linked to a different Red Hat org, and the browser
  reusing the wrong Red Hat SSO session (use a private window for `rosa login`).
- Machine type: the repo passes one resolved type to both the cluster and its worker pool
  (OCM's default changed to m7i.xlarge; a mismatch is immutable and fails the apply).
- Destroy order: operator CSV cleanup runs only after the ArgoCD CR, apps and MultiClusterHub are
  gone (before, it ran in parallel and the ArgoCD CR hung on its finalizer).
- Owner decisions, settled on 2026-10-13: Tier C, a $100 hard cap, us-east-2, and the istiod and
  proxy overrides below.
- Tier C, not B. The lab shape check could not run (the lab was powered off on 2026-10-13), so there
  is no evidence that an 8Gi istiod holds task 1's wide cells. C buys that headroom on mesh-a, plus
  task 6 in pods mode at 150-250 services × 2, for $1.50/h more than B. Its worst case, about $81,
  stays $19 under the cap.
- Tiers B and A are fallbacks, chosen before apply: B if r7i.2xlarge or the 64-vCPU quota is
  missing, A only without 52 vCPUs. The m7i.4xlarge variant of C is out: its worst case on the same
  timers is about $98.
- The 3-member partial mesh needs 4 clusters (the hub is never a mesh member). That is why the plan
  uses B or C over A: A loses the one task 3 case the lab cannot produce.
- 3 workers per member, fixed.
  - On b and c, istiod's 2 CPU / 8Gi request plus about 5 vCPU of ROSA, monitoring and ACM pods
    leave only about 2 vCPU free on 2 nodes.
  - mesh-a needs 3 nodes for its pods per node, not for CPU.
  - Fixed pools (min = max) are the structural cap on EC2 spend. A vCPU quota far above the need
    caps nothing and cannot be lowered; this account's (1848) is such a quota.
- Mesh-wide values are baked in at provision time, so no istiod restart happens before task 4's
  planned one.
  - istiod: request 2 CPU / 8Gi, limit 4 CPU / 16Gi.
  - Proxy requests: 20m / 64Mi.
  - The 16Gi limit is one value for every member. On the 16 GiB nodes of b and c it is nominal
    (GOMEMLIMIT 14.4 GiB, eviction above the 8Gi request), so task 1 watches their istiod by hand
    against 8Gi.
  - The proxy override changes scheduling only, and the campaign doc records it.
  - Checked before the 2026-10-14 platform apply: the `spoke-ossm-appset` override reaches the
    generated Applications' `helm.valuesObject` (with `clusterName` as a Helm parameter), and the
    Istio CR renders 1 replica, 2 CPU / 8Gi requested, 4 CPU / 16Gi limit, proxy 20m / 64Mi.
- Tasks 1 and 4 were never lab-validated. Their first ROSA runs start with a smoke step and a
  go/no-go before the expensive sweeps depend on them: task 4's read-only capture in P3, task 1's
  S1 in P6.
- Run order: cross-cluster measurements first (dataplane baseline, task 6), then task 3's gateway
  Service mutations on mesh-c only under one GitOps pause, then task 1 (single member, leaves
  thousands of namespaces, never deletes them in the window), then task 4's istiod delete last.
- Task 6 runs in pods mode, because config-only mode was not built for `vsdr`. It runs at 150 and
  250 services × 2 replicas on mesh-a, plus 60 × 2 per member across a and b, the most b can hold.
- Rejected on ROSA: touching `cacerts` (the lab already confirmed the CA race), OOM and
  liveness-probe tests, autoscaling worker pools, Tier D, and `rosa create cluster --expiration`
  (a hidden flag whose source says it is "not supported in production").
- Costs, checked 2026-10-13, with sources in window-plan.md:
  - Tier C is $8.2471/h: about $65 core (7.25 h), at most $77 extended, and about $81 worst case
    (auto-teardown at T0+8:15, billing ending about 45 min later).
  - Tier B is $6.75/h: about $48 core, at most $57 extended, and $60 worst case.
  - The earlier "about $3.5/hour for 3 small clusters" was really $4.31/h.
  - "$25-30/hour" for 20 members holds only for 2× m7i.xlarge members; campaign-shaped, it is about
    $248/h.
- AWS Budget `rosa-window-monthly` has a $100 limit, not month-to-date spend plus a ceiling: the
  account is otherwise idle. Its FORECASTED alert needs about 5 weeks of history before it can fire,
  so the ACTUAL alerts and the wall clock carry the load. Month-to-date before the 2026-10-14
  window was about $7, so its expected month totals are about $72 core, $84 extended and $88 worst
  case (in `status.md`).
- The wall clock is the spend meter: AWS Budgets refresh every 8-12 h, so they only catch leaks the
  next day. Hence T0 on disk, the spend estimate at every checkpoint, and an unattended,
  billing-first auto-teardown with both a monotonic and an absolute trigger.
- `003-auto-teardown.sh` destroys `module.rosa_hcp` before anything else: that stops the expensive
  hourly charges first and removes every controller that could recreate a load balancer while 002
  cleans up. After that targeted destroy the `by_cluster` output is empty, so 002 merges the saved
  copy, the output and the state, and with `--delete-interface-endpoints` also removes interface
  endpoints Terraform does not manage, only in VPCs with no instances left.
- `003-auto-teardown.sh --arm` defaults to `--fire-after 8h15m`, Tier C's deadline. The fallback
  tiers pass their own value.
- Failure modes that would silently void the $100 cap, closed in the scripts: a teardown needs an
  explicit `--now` (a re-arm that forgot `--arm` used to destroy mid-window); 002 and 003 drop an
  exported `TF_WORKSPACE` (rosa-hcp's destroy in the platform's `rosa` workspace reports success
  and destroys nothing); 003 passes the saved VPC list only once it exists (002 dies on a missing
  file and would never reach the state's VPCs); and `--arm` on WSL requires
  `instanceIdleTimeout=-1`, because systemd units do not keep a WSL distro running.
- A failed or unfired auto-teardown must reach an absent operator, and AWS Budgets lag 8-12 h.
  Tier C's worst case leaves $18.78 under the cap, about 2 h 15 min at the full rate. So both alerts
  are required, and both are free:
  - SNS with a confirmed email subscription. `--arm` refuses without one, and its "armed" email
    proves the path at T0.
  - A phone alarm at T0+9:15, an hour after the timer fires. It also covers what nothing on the host
    can report: a dead host, where the timer never runs.
  - A manual teardown started by T0+10:30 still ends billing under $100.
- The vCPU quota is not raised for a window. An account held at 64-72 vCPUs fails the one
  `rosa verify quota` check by design (rosa sizes it for five multi-AZ classic clusters), and the
  runbook reads the other quota lines instead of requesting an increase that can sit pending for
  hours. Near the need, the quota still stops an accidental extra cluster, which a fixed pool does
  not; well above it (as on this account), the fixed pools alone cap EC2.
- The orphaned ROSA classic roles and policies were removed on 2026-10-14 so the account holds only
  what the HCP path uses; they are recoverable from `~/.rosa-window/iam-backup/`.
- Learned in the 2026-10-14 window (record: `docs/campaigns/2026-10-14-rosa-validation/README.md`; the
  plan's top section lists the run-time corrections):
  - After the platform apply, an Application with no sync or health status means its cluster has no
    Argo CD controller shard; restart the `openshift-gitops-application-controller` pods (until
    BACKLOG 9.1 automates it).
  - Mid-window value changes go in a second `-var-file` outside the worktree (for example
    `~/.rosa-window/<name>.tfvars`). A later `-var-file` replaces a whole map variable, so it must
    repeat every `gitops_app_overrides` entry, not only the new one; check the plan diff before apply.
  - The timer can be moved any number of times (`--disarm`, then `--arm --fire-after <new>`); each
    move re-sends the "armed" email. Keep the phone alarms in step with it.
  - `003-auto-teardown.sh --now` is a sound primary teardown: 24.5 min to `CLEAN`, clusters gone
    after 17 min. The Resource Groups Tagging API keeps listing terminated and deleted resources for
    a while after; confirm each type's real state before treating it as a leftover.
- The 2026-10-29 OSSM functional mesh, owner decisions taken that day:
  - Hub + 3 members (4 clusters), because the mesh itself is to span 3 clusters and the hub never
    joins it; hub + 2 was the cheaper alternative (about $4.3/h).
  - Small sizing for functional OSSM work, not scale numbers: members on 2 fixed m7i.xlarge (the
    3-worker rule above exists only for the 2 CPU / 8Gi istiod), istiod 1 × 500m / 2Gi request,
    2 CPU / 4Gi limit (GOMEMLIMIT about 3.6 GiB; the 5-member run's peak istiod RSS was 1,271 MiB at
    4,000 namespaces). The hub keeps 2× m5.2xlarge, the shape every earlier run proved for ACM and
    OpenShift GitOps.
  - No auto-teardown and no spend cap: the owner tears it down by hand. The month was already over
    the `rosa-window-monthly` budget, so no budget alert will warn either; the clock in
    `~/.rosa-window/2026-10-29/t0` is the only meter.
  - The run used the session worktree rather than a sibling window worktree, so the state is backed
    up into `~/.rosa-window/2026-10-29/` after each apply in case that worktree is removed.
  - The repo revision is pinned to `14218c4` for reproducibility. To try OSSM changes through
    GitOps, push a branch to the repo and point `gitops_app_repo_revision` at it (then re-plan the
    platform), or hold a GitOps pause (`tests/tuning/006-gitops-pause.sh`) while editing live
    resources: Argo CD self-heals anything changed by hand otherwise.
  - Checked before the apply by two independent reviews: every value fits on 2 nodes per member
    (no HPA, no PDB at 1 replica, no affinity in the repo's charts) and the tfvars reach the charts
    (the `spoke-ossm-appset` override deep-merges and keeps the rosa-mode ingress NLB default).
  - The shared `cluster-admin` password cannot be rotated through Terraform on live clusters.
    `terraform plan -replace=random_password.cluster_admin` shows the 4 clusters "updated in-place",
    but the apply fails on each with `Attribute value cannot be changed` (the rhcs provider treats
    `admin_credentials` as immutable) after it has already replaced the password in state and
    deleted the kubeconfig. Recovery, done on 2026-10-29: copy the pre-apply
    `terraform/rosa-hcp/terraform.tfstate.backup` (Terraform writes it once per command, before the
    first state write) over `terraform.tfstate`, confirm its `random_password` matches the clusters'
    `admin_credentials` and the platform state's remote-state copy (compare hashes, never print the
    value), then `terraform plan` must show only the kubeconfig to create. A changed password needs
    new clusters, or an OCM-side htpasswd change that breaks the kubeconfig and the platform's
    Terraform access until the state is reconciled.

### How to drive it

1. P0, the day before ([window-plan.md, Prerequisites](window-plan.md#4-prerequisites-p0-the-day-before-no-cluster-spend)):
   - check the Tier C conditions (r7i.2xlarge offered, 64 vCPUs), or switch to a fallback tier;
   - pin the commit in a window worktree;
   - request quotas and create the $100 budget;
   - create the SNS topic and confirm its email subscription;
   - write the tfvars and run configs;
   - run every dry run, including `003-auto-teardown.sh --dry-run --sns-topic-arn <arn>`.
2. T0: write `t0`, arm `rosa-autoteardown` (T0+8:15, with `--sns-topic-arn`) and `rosa-warn`
   (T0+7:15), check that the "armed" email reached the phone, and set the phone alarms for T0+7:15,
   T0+7:45 and T0+9:15. Then apply rosa-hcp, save `by_cluster.json`, and apply the platform (Re-run
   above). Record T0 and the checkpoint clock times in `~/.rosa-window/<date>/status.md`.
3. Verify (above) and take the A0 inventory.
4. Run the phases in [window-plan.md, Run order](window-plan.md#5-run-order-tier-c).
   - At every checkpoint, announce the spend estimate and check `rosa whoami`.
   - When a deadline slips, cut from the cut list.
   - Treat the task 4 smoke (P3) and task 1's S1 (P6) as go/no-go gates: they are those tasks'
     first live runs.
5. Collect evidence and back up `tests/*/results/` off the laptop.
6. Tear down by the planned path, or billing-first; start no later than T0+7:45.
7. Audit until every check is empty; disarm the timers and cancel the T0+9:15 phone alarm. If the
   alarm rings first, confirm the auto-teardown's result as in Verify and recover; a manual
   `003 --now` must start by T0+10:30.
8. Write `docs/campaigns/<date>-rosa-validation/README.md` from the template with placeholders, update this
   file's opening paragraph to the new state and commit it; check Cost Explorer at T+1 and T+2.

For a build like 2026-10-29b (torn down 2026-10-29): when done, tear down from its demo worktree exactly
as in Verify and recover, "Functional run teardown" (`003-auto-teardown.sh --now`, then discard the
platform `rosa` workspace and run the audit; the rosa-hcp destroy also deletes the observability
bucket and its contents), stop the traffic loop if it still runs, delete
`~/rosa-demo-credentials.txt`, remove the demo worktree once the audit is empty, and update this
file's opening paragraph. Before that, the add-ons' turn-off path (toggle off, apply, check that
the Kiali and metrics objects are gone) is the one part not yet run live.

For the 2026-10-29 functional mesh, the loop is shorter: use the kubeconfig
(`export KUBECONFIG=<worktree>/terraform/rosa-hcp/kubeconfig`; members `cluster-002` to
`cluster-004`, hub `cluster-001`), try the OSSM change (through a pushed branch and a platform
re-plan, or under a GitOps pause), re-check the wiring gate and the mesh preflight after each change
(Verify and recover), and read the spend off `~/.rosa-window/2026-10-29/t0` at about $5.5/h. When
done, run the functional run teardown and the audit, update this file's opening paragraph to
"destroyed and audited empty on <date>", commit it, and check Cost Explorer at T+1 and T+2.
