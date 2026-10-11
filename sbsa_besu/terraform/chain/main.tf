# =============================================================================
# main.tf  (ROOT)
# -----------------------------------------------------------------------------
# PURPOSE
#   Wires the modules together for the (single-region) chain deployment. State
#   lives in S3 under a per-environment key (see backend.tf).
#
#   Modules: resource-group, network, eks, storage-csi, iam, secrets/pki,
#   besu (helm), rpc-access, observability, blockscout. All are instantiated
#   against the region provider (aws.primary).
# =============================================================================

# Derive a region-role-aware name prefix. For stage 1 we build the primary
# region; the prefix encodes the project so resources are self-describing.
locals {
  region_role = "primary"
  name_prefix = "${var.project_name}-${local.region_role}"

  # The Secrets Manager ARN pattern the Besu IRSA role is scoped to. Built from
  # the caller's account + primary region so pods can only read besu-node-*
  # secrets in this account/region.
  secrets_arn_prefix = "arn:aws:secretsmanager:${var.primary_region}:${data.aws_caller_identity.current.account_id}:secret:besu-node-*"

  # ---------------------------------------------------------------------------
  # Container image references (CLAUDE.md §5.2)
  # ---------------------------------------------------------------------------
  # Resolve the Besu tag: an explicit besu_version wins, else the pin carried in
  # container_images. The fallback used to be the literal "26.6.1" here, which
  # meant the version was written down twice and could disagree with itself.
  besu_pinned_version = var.besu_version != "" ? var.besu_version : var.container_images["besu"].tag

  _images = { for k, v in var.container_images :
    k => k == "besu" ? merge(v, { tag = local.besu_pinned_version }) : v
  }

  # host: the private registry when air-gapped, otherwise the image's own upstream.
  # repository: prefixed when each upstream gets its own repository namespace.
  # reference: digest wins over tag -- a tag is a mutable pointer, and re-pulling
  # one can return different bytes, so a node could come back as software nobody
  # reviewed (H38).
  image_ref = { for k, v in local._images : k => format("%s/%s%s",
    var.registry_host != "" ? var.registry_host : v.host,
    var.registry_host != "" && try(var.registry_repo_prefixes[v.host], "") != ""
    ? "${var.registry_repo_prefixes[v.host]}/${v.repository}"
    : v.repository,
    v.digest != "" ? "@${v.digest}" : ":${v.tag}",
  ) }

  besu_image  = local.image_ref["besu"]
  tools_image = local.image_ref["tools"]

  # The upstream charts' own images, rewritten the same way. Kept as registry +
  # repository rather than one string because kube-prometheus-stack takes them
  # as separate keys; the other charts take "<registry>/<repository>".
  chart_images = { for k, v in var.chart_images : k => {
    registry = var.registry_host != "" ? var.registry_host : v.host
    repository = (var.registry_host != "" && try(var.registry_repo_prefixes[v.host], "") != ""
    ? "${var.registry_repo_prefixes[v.host]}/${v.repository}" : v.repository)
    tag = v.tag
  } }

  # "" = each module's upstream https repository (only where there is egress).
  chart_repository = var.registry_host != "" ? "oci://${var.registry_host}/${var.registry_chart_path}" : ""

  # F24: the app-rpc POOL (besu-app-rpc-* pods + their TLS secrets) is sized by
  # app_rpc_count, but the app-rpc AWS edge (NLB/PrivateLink) is gated on
  # enable_app_rpc. Those two were independent, so a SWIFT-only chain
  # (enable_app_rpc=false) with a leftover app_rpc_count>0 would deploy orphan
  # app-rpc pods with no edge (and, lacking an issued app-rpc cert, crash-loop).
  # Gate the count on enable_app_rpc so the flag is the single source of truth.
  app_rpc_count_effective = var.enable_app_rpc ? var.app_rpc_count : 0
}

data "aws_caller_identity" "current" {
  provider = aws.primary
}

# -----------------------------------------------------------------------------
# RESOURCE GROUP — created first so the console grouping exists as resources
# come online. (Membership is tag-query based, so order does not actually
# matter for membership, but creating it early is tidy.)
# -----------------------------------------------------------------------------
module "resource_group" {
  source = "../modules/resource-group"
  providers = {
    aws = aws.primary
  }

  name_prefix    = var.project_name
  project_name   = var.project_name
  deletion_group = var.deletion_group
  region_role    = local.region_role
}

# -----------------------------------------------------------------------------
# NETWORK — VPC, subnets, NAT, routing, flow logs.
# cluster_name is passed in so subnet discovery tags match the EKS cluster.
# -----------------------------------------------------------------------------
# -----------------------------------------------------------------------------
# REMOVED: module "network".
# -----------------------------------------------------------------------------
# This project does NOT create the VPC. The network belongs to the bank's cloud
# team and is consumed as an input contract — see handover.tf and
# modules/network-contract, which creates nothing and asserts everything.
#
# Prime directive 0.1: if a plan ever shows a VPC, subnet, route table, IGW, NAT
# or Elastic IP being created, stop and treat it as a bug.
# -----------------------------------------------------------------------------

# -----------------------------------------------------------------------------
# EKS — cluster, OIDC provider, managed node group, core addons.
# -----------------------------------------------------------------------------
module "eks" {
  source = "../modules/eks"
  providers = {
    aws = aws.primary
  }

  # CT-3: private-registry CA, installed before the first image pull.
  extra_ca_cert_pem = var.registry_ca_cert_pem

  name_prefix                  = local.name_prefix
  cluster_name                 = "${local.name_prefix}-eks"
  kubernetes_version           = var.kubernetes_version
  vpc_id                       = module.network_contract.vpc_id
  private_subnet_ids           = values(module.network_contract.ledger_subnet_ids) # #11 ledger-dedicated
  endpoint_public_access       = var.eks_public_access
  endpoint_public_access_cidrs = var.eks_public_access_cidrs
  node_count                   = var.worker_node_count
  node_min                     = var.worker_node_min
  node_max                     = var.worker_node_max
  instance_type                = var.validator_instance_type
  node_volume_size_gib         = var.node_volume_size_gib
  log_retention_days           = var.log_retention_days
  # H7: envelope-encrypt K8s Secrets in etcd with a dedicated CMK (one-way; keep true for prod).
  enable_secrets_encryption        = var.enable_secrets_encryption
  secrets_kms_deletion_window_days = var.kms_deletion_window_days
  # H10: pin core addons (resolve-then-pin) + PRESERVE on update. H6: NetworkPolicy agent.
  addon_versions        = var.addon_versions
  enable_network_policy = var.enable_network_policy
  # H20: customer CMK for node EBS at-rest (empty = AWS-managed).
  data_cmk_arn = var.data_cmk_arn
  # H5: permissions boundary on the cluster + node roles.
  permissions_boundary = local.iam_permissions_boundary_arn
}

# -----------------------------------------------------------------------------
# IAM — IRSA role for Besu pods to read keys from Secrets Manager.
# Depends on the EKS OIDC provider existing.
# -----------------------------------------------------------------------------
module "iam" {
  source = "../modules/iam"
  providers = {
    aws = aws.primary
  }

  name_prefix        = local.name_prefix
  oidc_provider_arn  = module.eks.oidc_provider_arn
  oidc_provider_url  = module.eks.oidc_provider_url
  namespace          = var.besu_namespace # was the literal "besu": the IRSA trust must name the namespace the pods are in
  secrets_arn_prefix = local.secrets_arn_prefix
  # C12: when set, pod/genesis roles get a scoped kms:Decrypt (+GenerateDataKey)
  # on the node-key CMK so the CSI driver / genesis Job can use CMK-encrypted secrets.
  node_key_cmk_arn = local.node_key_cmk_arn
  # H5: permissions boundary on both IRSA roles.
  permissions_boundary = local.iam_permissions_boundary_arn
}

# -----------------------------------------------------------------------------
# STORAGE + SECRETS CSI — EBS CSI driver, gp3 StorageClass, Secrets Store CSI.
# Uses the helm/kubernetes providers (configured below) which require the
# cluster to exist, so this implicitly depends on module.eks via those values.
# -----------------------------------------------------------------------------
module "storage_csi" {
  source = "../modules/storage-csi"
  providers = {
    aws = aws.primary
  }

  name_prefix                 = local.name_prefix
  cluster_name                = module.eks.cluster_name
  oidc_provider_arn           = module.eks.oidc_provider_arn
  oidc_provider_url           = module.eks.oidc_provider_url
  reclaim_policy              = var.storage_reclaim_policy         # prod: Retain (keeps chain data); non-prod: Delete (clean teardown)
  deploy_in_cluster_resources = var.deploy_in_cluster_resources    # false for laptop applies (private endpoint unreachable); true from inside the VPC
  volume_tags                 = local.common_tags                  # C11: CSI-provisioned EBS bypasses default_tags; stamp DeletionGroup etc. on PVC volumes
  ebs_csi_addon_version       = var.ebs_csi_addon_version          # H10: pin the EBS CSI addon (empty = EKS default)
  data_cmk_arn                = var.data_cmk_arn                   # H20: customer CMK for chain-data PVCs (empty = AWS-managed)
  permissions_boundary        = local.iam_permissions_boundary_arn # H5: cap on the EBS CSI IRSA role
  # PORTING item 4: upstream charts and their images from the mirror ("" / registry_host unset = upstream).
  chart_repository = local.chart_repository
  chart_images     = local.chart_images
}

# -----------------------------------------------------------------------------
# PKI — CA bootstrap (stage 2). Self-managed CA by default (ca_mode=""); AWS
# Private CA when ca_mode="aws". Pure AWS/tls API calls — applies from anywhere.
# -----------------------------------------------------------------------------
module "pki" {
  source = "../modules/pki"
  providers = {
    aws = aws.primary
  }

  name_prefix      = local.name_prefix
  ca_mode          = var.ca_mode
  ca_common_name   = var.ca_common_name
  ca_organization  = var.ca_organization
  ca_validity_days = var.ca_validity_days
}

# -----------------------------------------------------------------------------
# SECRETS — Secrets Manager content (stage 2): CA material (from pki), keystore/
# truststore/JWT passwords, and the validator/bootnode node-key CONTAINERS whose
# values come from provided keys or the stage-3 genesis tooling. Also installs
# the in-cluster Secrets Store CSI AWS provider (gated by
# deploy_in_cluster_resources). depends_on the storage_csi module so the generic
# Secrets Store CSI driver (installed there) exists before the AWS provider that
# plugs into it.
# -----------------------------------------------------------------------------
module "secrets" {
  source = "../modules/secrets"
  providers = {
    aws = aws.primary
  }

  name_prefix                 = local.name_prefix
  ca_mode                     = var.ca_mode
  ca_cert_pem                 = module.pki.ca_cert_pem
  ca_private_key_pem          = module.pki.ca_private_key_pem
  validator_count             = var.validator_count
  bootnode_count              = var.bootnode_count
  rpc_node_count              = var.rpc_node_count
  app_rpc_node_count          = local.app_rpc_count_effective # F24: gated on enable_app_rpc
  explorer_rpc_node_count     = var.explorer_rpc_count
  use_provided_validator_keys = var.use_provided_validator_keys
  validator_private_keys      = var.validator_private_keys
  recovery_window_days        = var.secret_recovery_window_days
  deploy_in_cluster_resources = var.deploy_in_cluster_resources
  # C12: encrypt the node-key + CA-private-key secrets with this CMK ("" = the
  # AWS-managed aws/secretsmanager key).
  node_key_cmk_arn = local.node_key_cmk_arn

  # PORTING item 4: upstream charts and their images from the mirror ("" / registry_host unset = upstream).
  chart_repository = local.chart_repository
  chart_images     = local.chart_images

  depends_on = [module.storage_csi]
}

# -----------------------------------------------------------------------------
# RUNNER BOOTSTRAP SECRETS (stage 3) — the GitHub clone token + deploy-config
# bundle the In-VPC EC2 Runner (and the app EC2) consume. These stay in the CHAIN
# state (AWS-layer, shared); the runner EC2 ITSELF is a separate root now
# (terraform/runner/, C1). See CLAUDE.md §3.
# -----------------------------------------------------------------------------
# --- Runner code + config delivery (F15/F16) ---------------------------------
# These live at ROOT (not in the runner module) so they are created during the
# laptop AWS-layer apply and therefore EXIST before the runner boots.
#
#   1) runner_artifacts (S3)   — the toolchain + source bundle the runner fetches
#      at boot. D-21: the VPC has NO egress, so the runner cannot dnf-install,
#      cannot curl dl.k8s.io, and cannot clone GitHub — each of those HANGS until
#      timeout rather than failing, and the runner is the only path to the private
#      EKS API. The laptop downloads and verifies the toolchain (where there IS
#      internet) and pushes it here; the runner pulls it over the S3 GATEWAY
#      endpoint, which is free and already required for ECR image layers.
#      Populate with scripts/runner/push-runner-bundle.sh.
#
#   2) runner_deploy_config (Secrets Manager) — the gitignored env config
#      (primary.tfvars, app identity/.env). TF creates the EMPTY container so
#      `destroy` cleans it; the VALUE is pushed from the laptop by
#      scripts/runner/push-deploy-config.sh (a base64 .tar.gz). Kept in Secrets
#      Manager rather than the bundle bucket ON PURPOSE: it is the only part of
#      the delivery that is secret, and mixing it into an S3 object alongside
#      ordinary source is how a tfvars full of keys ends up somewhere nobody
#      audits.
#
# The GitHub PAT path is GONE (D-21). It required internet the VPC does not have,
# and it was a recurring source of findings on its own — F28 (a rotated PAT left a
# stale secret, so the runner looked healthy with an empty /opt/besu-deploy), H18
# (keeping the token off the git argv and out of failure logs) and H39 (rotate the
# runner PAT). Deleting the credential deletes the whole class.

resource "aws_s3_bucket" "runner_artifacts" {
  provider = aws.primary
  bucket   = "${local.name_prefix}-runner-artifacts"

  # No-deletion-protection rule: teardown must stay instant. force_destroy lets
  # `terraform destroy` remove the bucket with the bundle still in it, instead of
  # failing on BucketNotEmpty and leaving a manual step in the teardown path.
  force_destroy = true
}

resource "aws_s3_bucket_public_access_block" "runner_artifacts" {
  provider                = aws.primary
  bucket                  = aws_s3_bucket.runner_artifacts.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "runner_artifacts" {
  provider = aws.primary
  bucket   = aws_s3_bucket.runner_artifacts.id
  rule {
    apply_server_side_encryption_by_default {
      # SSE-S3, not the C12 CMK: this bucket holds public tool binaries and the
      # committed source tree, neither of which is secret. The secret half of the
      # delivery (the env config) lives in Secrets Manager under the CMK.
      sse_algorithm = "AES256"
    }
  }
}

# Versioning: a bad bundle push is otherwise unrecoverable without a laptop that
# still has the previous toolchain. Cheap (a few hundred MB) and it makes
# "roll back to the bundle that worked" a real option during a deploy-test.
resource "aws_s3_bucket_versioning" "runner_artifacts" {
  provider = aws.primary
  bucket   = aws_s3_bucket.runner_artifacts.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_secretsmanager_secret" "runner_deploy_config" {
  provider                = aws.primary
  name                    = "${local.name_prefix}-runner-deploy-config"
  description             = "Gitignored env config bundle (primary.tfvars, app identity/.env) for the runner — a base64 .tar.gz pushed from the laptop (F16)."
  recovery_window_in_days = var.secret_recovery_window_days
}

# NOTE (C1): the In-VPC EC2 Runner itself now lives in its OWN root/state at
# terraform/runner/ (it reads these secret names + the VPC/cluster outputs via
# terraform_remote_state). Keeping it OUT of this state is what removes the F4/F5
# `-var deploy_runner=true` traps — a chain apply can no longer create or destroy
# the runner. The two bootstrap SECRETS above stay here (AWS-layer, shared by the
# runner AND the app EC2). Apply the runner with:
#   cd terraform/runner && terraform init -backend-config=... && terraform apply

# -----------------------------------------------------------------------------
# RPC ACCESS (stage 4) — internal NLB edge (TLS passthrough) + SIPN-locked SG +
# PrivateLink hook + AWS Load Balancer Controller. AWS-layer parts apply from
# anywhere; the LB Controller (in-cluster) is gated by deploy_in_cluster_resources.
# -----------------------------------------------------------------------------
module "rpc_access" {
  source = "../modules/rpc-access"
  providers = {
    aws = aws.primary
  }

  name_prefix                       = local.name_prefix
  enable_rpc_ingress                = var.enable_rpc_ingress
  enable_deletion_protection        = var.enable_deletion_protection # H13: true for prod (protect SWIFT/app NLB DNS)
  deploy_in_cluster_resources       = var.deploy_in_cluster_resources
  vpc_id                            = module.network_contract.vpc_id
  vpc_cidr                          = var.vpc_cidr_primary
  private_subnet_ids                = values(module.network_contract.lb_subnet_ids) # #4 tagged internal-elb
  cluster_name                      = module.eks.cluster_name
  cluster_primary_security_group_id = module.eks.node_security_group_id
  region                            = var.primary_region
  oidc_provider_arn                 = module.eks.oidc_provider_arn
  oidc_provider_url                 = module.eks.oidc_provider_url
  rpc_port                          = var.swift_rpc_port
  swift_sipn_allowed_cidrs          = var.swift_sipn_allowed_cidrs
  enable_privatelink                = var.enable_app_privatelink
  permissions_boundary              = local.iam_permissions_boundary_arn # H5: cap on the LBC IRSA role

  # Stage 8: separate app-rpc edge (A′) — own NLB + HTTP/WS TGs + PrivateLink svc.
  enable_app_rpc_ingress = var.enable_app_rpc
  app_rpc_http_port      = var.app_rpc_http_port
  app_rpc_ws_port        = var.app_rpc_ws_port
  app_rpc_ws_enabled     = var.app_rpc_ws_enabled
  app_rpc_allowed_cidrs  = var.app_rpc_allowed_cidrs

  # PORTING item 4: upstream charts and their images from the mirror ("" / registry_host unset = upstream).
  chart_repository = local.chart_repository
  chart_images     = local.chart_images
}

# -----------------------------------------------------------------------------
# H6 — cross-variable safety guards. A validation{} block can only see its own
# variable, so bind the NetworkPolicy toggles (and the ops-JWT escape hatch) here,
# where a precondition can reference several vars and FAIL the plan hard.
#   1. network_policy.enabled without the CNI NetworkPolicy agent (enable_network_policy)
#      would ship UNENFORCED policies (fail-open) — refuse that combination.
#   2. ops_rpc_allow_no_jwt exposes QBFT/ADMIN/PERM/DEBUG on 8545 with no auth; permit it
#      ONLY when NetworkPolicy is actually enforced (both toggles on).
# -----------------------------------------------------------------------------
# Supply-chain guards (CLAUDE.md §5.2, H38)
# -----------------------------------------------------------------------------
# These fail the PLAN. The failure they prevent -- a pod that cannot reach its
# registry -- appears at apply time as ImagePullBackOff with no mention of the
# registry, and in an air-gapped VPC as a HANG rather than a refusal.
# -----------------------------------------------------------------------------
resource "terraform_data" "image_supply_chain" {
  lifecycle {
    precondition {
      condition = !var.require_image_digests || alltrue([
        for k, v in var.container_images : v.digest != ""
      ])
      error_message = "require_image_digests=true but these images are still tag-pinned: ${join(", ", [for k, v in var.container_images : k if v.digest == ""])}. A tag is a mutable pointer -- re-pulling it can return different bytes, so a validator could restart as software nobody reviewed. Resolve digests with scripts/preflight/verify-images.sh. (H38)"
    }
    precondition {
      condition     = var.registry_host == "" || !contains([for k, v in local.image_ref : v], "")
      error_message = "registry_host is set but at least one image resolved to an empty reference."
    }
    precondition {
      condition     = var.registry_host == "" || var.environment != "prod" || var.registry_ca_cert_pem != "" || var.registry_cert_publicly_trusted
      error_message = "registry_host is set for a prod deployment but registry_ca_cert_pem is empty. If the registry presents a certificate from a private CA, every image pull fails with 'x509: certificate signed by unknown authority', reported to you as a bare ImagePullBackOff naming neither the registry nor the certificate. Supply the CA PEM, or set registry_cert_publicly_trusted = true if the registry genuinely uses a publicly-trusted certificate. (CT-3)"
    }
    precondition {
      condition     = var.registry_host != "" || var.environment != "prod"
      error_message = "registry_host is empty in a prod deployment, so every image would be pulled from its public upstream (docker.io / ghcr.io). The production VPC has no egress: those pulls do not fail cleanly, they HANG until timeout and surface as ImagePullBackOff with nothing naming the registry. Set registry_host to the private ECR registry. (CT-3)"
    }
  }
}

resource "terraform_data" "hardening_guards" {
  lifecycle {
    precondition {
      condition     = !var.network_policy.enabled || var.enable_network_policy
      error_message = "network_policy.enabled=true requires enable_network_policy=true (the VPC CNI NetworkPolicy agent) — otherwise the NetworkPolicy objects render but are silently UNENFORCED (fail-open). Enable the agent or disable network_policy. (H6)"
    }
    precondition {
      condition     = !var.ops_rpc_allow_no_jwt || (var.network_policy.enabled && var.enable_network_policy)
      error_message = "ops_rpc_allow_no_jwt=true exposes the privileged ops listener (QBFT/ADMIN/PERM/DEBUG/TXPOOL) UNAUTHENTICATED on 8545. It is only permitted when NetworkPolicy is ENFORCED (network_policy.enabled=true AND enable_network_policy=true). Provide an ops JWT (ops_rpc_jwt_pubkey_secret_name) instead. (H6)"
    }
  }
}

# BESU WORKLOADS (stage 3) — the genesis bootstrap Job + one StatefulSet per
# node, via Helm. Uses the helm provider, so it ONLY does anything when
# deploy_in_cluster_resources = true (run from the In-VPC EC2 Runner). When false
# (laptop apply) the module instantiates but creates zero releases.
# -----------------------------------------------------------------------------
module "besu" {
  source = "../modules/besu"

  deploy    = var.deploy_in_cluster_resources
  namespace = var.besu_namespace
  region    = var.primary_region

  besu_image           = local.besu_image
  tools_image          = local.tools_image
  chain_id             = var.chain_id
  block_period_seconds = var.qbft_block_period_seconds

  validator_count    = var.validator_count
  bootnode_count     = var.bootnode_count
  rpc_count          = var.rpc_node_count
  app_rpc_count      = local.app_rpc_count_effective # F24: gated on enable_app_rpc
  explorer_rpc_count = var.explorer_rpc_count

  # C4: tells the genesis Job to build extraData from the operator-supplied validator
  # keys (in Secrets Manager) rather than freshly-generated ones.
  use_provided_validator_keys = var.use_provided_validator_keys

  # H2: re-genesis guard (default false). Keep false for normal applies so the
  # genesis Job can never overwrite a live chain's genesis. Flip true ONLY for a
  # deliberate, destructive re-genesis after wiping node-key secrets + validator PVCs.
  allow_regenesis = var.allow_regenesis

  # H11: QBFT 25<->26 wire-compat flag (default false). The rolling upgrade script
  # sets it via --set for a mixed-version window; this is only for a first-create deploy.
  bft_legacy_protocol_encoding = var.bft_legacy_protocol_encoding
  # H23: RPC host-allowlist (settable; default "*") + CORS origins (default "none").
  rpc_host_allowlist = var.rpc_host_allowlist
  rpc_cors_origins   = var.rpc_cors_origins

  validator_secret_names    = module.secrets.validator_secret_names
  bootnode_secret_names     = module.secrets.bootnode_secret_names
  rpc_secret_names          = module.secrets.rpc_secret_names
  app_rpc_secret_names      = module.secrets.app_rpc_secret_names
  explorer_rpc_secret_names = module.secrets.explorer_rpc_secret_names
  ca_cert_secret_name       = module.secrets.ca_cert_secret_name

  genesis_role_arn = module.iam.besu_genesis_role_arn
  pod_role_arn     = module.iam.besu_secrets_role_arn

  node_permissioning_mode     = var.node_permissioning_mode
  account_permissioning_mode  = var.account_permissioning_mode
  permissioning_admin_account = var.permissioning_admin_account
  # H8: union the app signer EOA (from gen-app-identity.sh via app-identity.tfvars)
  # into BOTH the account allowlist AND the funded accounts, additively (concat, not
  # replace, so primary.tfvars entries are preserved). Under account_permissioning_mode
  # ="local" the signer must be allowlisted or its set()/deploy tx is rejected; on the
  # zero-gas chain it must also be funded. distinct() dedups if it is also hand-listed.
  initial_account_allowlist = distinct(concat(var.initial_account_allowlist, var.app_signer_account != "" ? [var.app_signer_account] : []))
  genesis_funded_accounts   = distinct(concat(var.genesis_funded_accounts, var.app_signer_account != "" ? [var.app_signer_account] : [])) # F20 + H8

  # Falls back to the literal SC name when storage_csi skipped the in-cluster
  # StorageClass (laptop apply); the real name is created from the runner.
  storage_class_name   = coalesce(module.storage_csi.storage_class_name, "besu-gp3")
  data_volume_size_gib = var.besu_data_volume_size_gib

  # Stage 4 mTLS edge: enable native Besu mTLS + bind RPC pods to the NLB TG.
  rpc_mtls_enabled = var.rpc_mtls_enabled
  rpc_auth_mode    = var.rpc_auth_mode
  # coalesce null -> "" so rpc_edge's count (… != "") is false when the NLB edge
  # is disabled (the output is null, and null != "" would wrongly be true).
  rpc_target_group_arn = module.rpc_access.rpc_target_group_arn != null ? module.rpc_access.rpc_target_group_arn : ""

  # Stage 8: app-rpc pool wiring — server-TLS + JWT secret names (from secrets),
  # WS port, the validator-internal ops listener, and the app NLB target groups
  # (from rpc-access) the besu-app-rpc-edge release binds the app-rpc pods into.
  rpc_ws_port                           = var.app_rpc_ws_port
  app_rpc_tls_enabled                   = var.app_rpc_tls_enabled
  app_rpc_ws_enabled                    = var.app_rpc_ws_enabled
  app_rpc_auth_enabled                  = var.app_rpc_auth_enabled
  app_rpc_keystore_secret_name          = module.secrets.app_rpc_tls_secret_names.keystore
  app_rpc_keystore_password_secret_name = module.secrets.app_rpc_tls_secret_names.keystore_password
  app_rpc_jwt_pubkey_secret_name        = module.secrets.app_rpc_tls_secret_names.jwt_pubkey
  app_rpc_target_group_arns             = module.rpc_access.app_rpc_target_group_arns
  ops_rpc_enabled                       = var.ops_rpc_enabled
  ops_rpc_jwt_pubkey_secret_name        = var.ops_rpc_jwt_pubkey_secret_name # H6
  ops_rpc_allow_no_jwt                  = var.ops_rpc_allow_no_jwt           # H6
  network_policy                        = var.network_policy                 # H6

  # rpc_access must precede so the LB Controller (TargetGroupBinding CRD) exists
  # before the besu-rpc-edge release.
  depends_on = [module.secrets, module.storage_csi, module.rpc_access]
}

# -----------------------------------------------------------------------------
# OBSERVABILITY (stage 5) — SNS/CloudTrail/alarms/Fluent-Bit (AWS-layer) +
# kube-prometheus-stack + Fluent Bit + Besu monitoring (in-cluster, gated).
# -----------------------------------------------------------------------------
module "observability" {
  source = "../modules/observability"
  providers = {
    aws = aws.primary
  }

  name_prefix                 = local.name_prefix
  region                      = var.primary_region
  cluster_name                = module.eks.cluster_name
  oidc_provider_arn           = module.eks.oidc_provider_arn
  oidc_provider_url           = module.eks.oidc_provider_url
  deploy_in_cluster_resources = var.deploy_in_cluster_resources
  alert_email                 = var.alert_email
  besu_namespace              = var.besu_namespace
  enable_cloudtrail           = var.enable_cloudtrail
  cloudtrail_force_destroy    = var.cloudtrail_force_destroy # H19: false for prod (protect audit bucket)
  cloudtrail_kms_key_arn      = var.cloudtrail_kms_key_arn   # H19: customer CMK for trail SSE (empty = AES256)
  log_retention_days          = var.log_retention_days
  grafana_admin_password      = var.grafana_admin_password
  rpc_nlb_arn                 = module.rpc_access.rpc_nlb_arn != null ? module.rpc_access.rpc_nlb_arn : ""
  rpc_target_group_arn        = module.rpc_access.rpc_target_group_arn != null ? module.rpc_access.rpc_target_group_arn : ""
  enable_nlb_alarm            = var.enable_rpc_ingress
  # C12: log every KMS Decrypt on the node-key CMK as a CloudTrail data event.
  node_key_cmk_arn       = local.node_key_cmk_arn
  enable_kms_data_events = var.enable_kms_data_events
  # H5: cap on the fluent-bit + alertmanager IRSA roles.
  permissions_boundary = local.iam_permissions_boundary_arn

  # PORTING item 4: upstream charts and their images from the mirror ("" / registry_host unset = upstream).
  chart_repository = local.chart_repository
  chart_images     = local.chart_images

  # B51: the charts install after the LB controller through this REFERENCE, not a
  # module-level depends_on. depends_on = [module.rpc_access] deferred every data
  # source here (account ID, IAM policy documents) whenever rpc_access had pending
  # changes — i.e. on every in-cluster plan — which planned a CloudTrail bucket
  # REPLACEMENT and two IRSA trust-policy rewrites. The CD-53 gate refused it.
  install_after = module.rpc_access.lb_controller_release
}

# =============================================================================
# STAGE 9 — BLOCKSCOUT EXPLORER (in-cluster, private). Indexes the dedicated
# explorer-rpc pool over ClusterIP (eth+debug/trace). Gated by enable_blockscout
# AND deploy_in_cluster_resources (needs the private EKS endpoint, so it runs
# from the In-VPC EC2 Runner, like the Besu/observability releases). depends_on the
# besu module so the explorer-rpc pool + gp3 StorageClass exist first.
# =============================================================================
module "blockscout" {
  source = "../modules/blockscout"

  deploy    = var.deploy_in_cluster_resources && var.enable_blockscout && var.explorer_rpc_count > 0
  namespace = var.besu_namespace
  chart_dir = "${path.module}/../../helm/charts" # B52: this root is terraform/chain/ since the four-root split; ../helm resolved to terraform/helm

  chain_id     = var.chain_id
  network_name = var.blockscout_network_name
  subnetwork   = var.project_name
  rpc_http_url = module.besu.explorer_rpc_http_url
  rpc_ws_url   = module.besu.explorer_rpc_ws_url

  blockscout_image    = local.image_ref["blockscout"]
  frontend_image      = local.image_ref["frontend"]
  stats_image         = local.image_ref["stats"]
  visualizer_image    = local.image_ref["visualizer"]
  proxy_image         = local.image_ref["proxy"]
  access_host         = var.blockscout_access_host
  postgres_image      = local.image_ref["postgres"]
  storage_class_name  = module.storage_csi.storage_class_name
  pg_storage_size_gib = var.blockscout_pg_storage_size_gib

  depends_on = [module.besu, module.storage_csi]
}

# =============================================================================
# KUBERNETES + HELM PROVIDERS
# -----------------------------------------------------------------------------
# These providers talk to the EKS cluster's API. They authenticate using a
# short-lived token obtained via the AWS CLI/exec plugin so we never store a
# static kubeconfig. They depend on the cluster's endpoint + CA, which only
# exist after module.eks creates the cluster.
#
# NOTE: configuring providers from resource attributes (cluster endpoint) means
# the very first `apply` creates the cluster, then configures these providers in
# the same run. Terraform handles this, but if you ever see a provider-config
# error on a brand-new apply, run the EKS module first (-target) then the rest —
# documented in the manual guide's troubleshooting section.
# =============================================================================
provider "kubernetes" {
  host                   = module.eks.cluster_endpoint
  cluster_ca_certificate = base64decode(module.eks.cluster_ca_certificate)

  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args = [
      "eks", "get-token",
      "--cluster-name", module.eks.cluster_name,
      "--region", var.primary_region,
    ]
  }
}

# ECR login for the OCI chart repository (PORTING item 4). Read only when the
# charts come from the registry AND this apply installs them -- an AWS-layer
# apply has no use for a token, and a 12-hour credential should not be fetched
# for nothing. registry_id is the account in registry_host, which is a central
# shared-services account in production (#25b), not necessarily ours.
data "aws_ecr_authorization_token" "charts" {
  count    = local.chart_repository != "" && var.deploy_in_cluster_resources ? 1 : 0
  provider = aws.primary

  registry_id = split(".", var.registry_host)[0]
}

provider "helm" {
  dynamic "registry" {
    for_each = data.aws_ecr_authorization_token.charts
    content {
      url      = "oci://${var.registry_host}"
      username = registry.value.user_name
      password = registry.value.password
    }
  }

  kubernetes {
    host                   = module.eks.cluster_endpoint
    cluster_ca_certificate = base64decode(module.eks.cluster_ca_certificate)

    exec {
      api_version = "client.authentication.k8s.io/v1beta1"
      command     = "aws"
      args = [
        "eks", "get-token",
        "--cluster-name", module.eks.cluster_name,
        "--region", var.primary_region,
      ]
    }
  }
}
