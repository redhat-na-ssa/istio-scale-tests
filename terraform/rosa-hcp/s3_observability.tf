# Optional object storage for ACM Observability's Thanos on the hub (cluster 1):
# terraform/platform reads the bucket and role from this state when acm_observability is on.
# The role trusts the hub's OIDC provider (create_oidc in main.tf), so the Thanos pods
# assume it with their projected ServiceAccount token (STS). The static key is a fallback.

locals {
  acm_obs_name = "${local.first_cluster_key}-acm-obs"
  # The module creates the OIDC provider for https://<oidc_endpoint_url>; the IAM provider ARN
  # and the trust condition key use the host and path without the scheme.
  acm_obs_oidc_host = var.acm_observability_bucket ? trimprefix(module.rosa_hcp[local.first_cluster_key].oidc_endpoint_url, "https://") : ""
}

data "aws_caller_identity" "current" {
  count = var.acm_observability_bucket ? 1 : 0
}

data "aws_partition" "current" {
  count = var.acm_observability_bucket ? 1 : 0
}

# force_destroy: Thanos blocks inside never block a destroy.
resource "aws_s3_bucket" "acm_observability" {
  count = var.acm_observability_bucket ? 1 : 0

  bucket_prefix = "${local.acm_obs_name}-"
  force_destroy = true
  tags          = var.common_tags

  lifecycle {
    # S3 allows 37 characters in a bucket_prefix (63 minus the 26-character suffix).
    precondition {
      condition     = length("${local.acm_obs_name}-") <= 37
      error_message = "The hub cluster name is too long for an S3 bucket_prefix (28 characters at most)."
    }
  }
}

resource "aws_s3_bucket_public_access_block" "acm_observability" {
  count = var.acm_observability_bucket ? 1 : 0

  bucket                  = aws_s3_bucket.acm_observability[0].id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "acm_observability" {
  count = var.acm_observability_bucket ? 1 : 0

  bucket = aws_s3_bucket.acm_observability[0].id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# What Thanos needs at runtime: list the bucket, read, write and delete its objects.
resource "aws_iam_policy" "acm_observability" {
  count = var.acm_observability_bucket ? 1 : 0

  name        = "${local.acm_obs_name}-s3"
  description = "ACM Observability Thanos: read and write its S3 bucket."
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["s3:ListBucket"]
        Resource = aws_s3_bucket.acm_observability[0].arn
      },
      {
        Effect   = "Allow"
        Action   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
        Resource = "${aws_s3_bucket.acm_observability[0].arn}/*"
      },
    ]
  })
  tags = var.common_tags
}

# Assumed by the Thanos ServiceAccounts (observability-thanos-query, -store-shard, -compact,
# -rule, -receive) through the hub's OIDC provider. StringLike, so their exact names do not matter.
resource "aws_iam_role" "acm_observability" {
  count = var.acm_observability_bucket ? 1 : 0

  name                  = "${local.acm_obs_name}-s3"
  force_detach_policies = true
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Federated = "arn:${data.aws_partition.current[0].partition}:iam::${data.aws_caller_identity.current[0].account_id}:oidc-provider/${local.acm_obs_oidc_host}"
      }
      Action = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringLike = {
          "${local.acm_obs_oidc_host}:sub" = "system:serviceaccount:open-cluster-management-observability:observability-thanos-*"
        }
      }
    }]
  })
  tags = var.common_tags
}

resource "aws_iam_role_policy_attachment" "acm_observability" {
  count = var.acm_observability_bucket ? 1 : 0

  role       = aws_iam_role.acm_observability[0].name
  policy_arn = aws_iam_policy.acm_observability[0].arn
}

# Static-key fallback (acm_observability_bucket_static_key): a user with the same policy and an
# access key, which terraform/platform writes into thanos.yaml. The key is kept in this state.
resource "aws_iam_user" "acm_observability" {
  count = var.acm_observability_bucket && var.acm_observability_bucket_static_key ? 1 : 0

  name          = "${local.acm_obs_name}-s3"
  force_destroy = true
  tags          = var.common_tags
}

resource "aws_iam_user_policy_attachment" "acm_observability" {
  count = var.acm_observability_bucket && var.acm_observability_bucket_static_key ? 1 : 0

  user       = aws_iam_user.acm_observability[0].name
  policy_arn = aws_iam_policy.acm_observability[0].arn
}

resource "aws_iam_access_key" "acm_observability" {
  count = var.acm_observability_bucket && var.acm_observability_bucket_static_key ? 1 : 0

  user = aws_iam_user.acm_observability[0].name
}
