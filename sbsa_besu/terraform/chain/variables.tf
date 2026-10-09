# =============================================================================
# variables.tf  (ROOT)
# -----------------------------------------------------------------------------
# PURPOSE
#   Declares every input variable for the whole deployment. This is the single
#   schema that the prod tfvars files populate. Variables consumed only in later
#   build stages are declared here anyway so the schema is STABLE from stage 1 —
#   you will not have to restructure tfvars as later stages land.
#
# CONVENTIONS
#   * Every variable has a description (shown in `terraform plan` and docs).
#   * Sensitive values are marked `sensitive = true` so Terraform redacts them
#     in console output.
#   * Validation blocks enforce "safe-by-construction" rules at plan time —
#     e.g. CIDR sanity, region non-equality — so misconfigurations fail BEFORE
#     any resource is touched. Heavier cross-field checks (CIDR non-overlap,
#     admin-account-in-allowlist) live in scripts/validate-config.sh because
#     they need logic beyond a single-variable validation block.
# =============================================================================

# -----------------------------------------------------------------------------
# IDENTITY & TAGGING
# -----------------------------------------------------------------------------
variable "project_name" {
  description = "Static identifier for this system; becomes the Project tag and name prefix for resources."
  type        = string
  default     = "besu-aws-prod"

  validation {
    # Lowercase alphanumerics and hyphens only — safe for use in AWS resource
    # names, DNS labels, and the Resource Group name.
    condition     = can(regex("^[a-z0-9-]+$", var.project_name))
    error_message = "project_name must contain only lowercase letters, numbers, and hyphens."
  }
}

variable "deletion_group" {
  description = <<-EOT
    UNIQUE-per-deployment identifier. Applied as the DeletionGroup tag to every
    resource and used as the discovery key by the full-delete script. Use a
    distinct value per independent deployment (e.g. "prod-za-2026-06"). This is
    what prevents the full-delete script from ever touching a different
    deployment's resources.
  EOT
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9-]+$", var.deletion_group)) && length(var.deletion_group) >= 4
    error_message = "deletion_group must be >= 4 chars, lowercase letters, numbers, and hyphens only."
  }
}

variable "owner" {
  description = "Team or email accountable for these resources; becomes the Owner tag."
  type        = string
}

variable "cost_center" {
  description = "Finance cost-center code for chargeback; becomes the CostCenter tag."
  type        = string
  default     = "unassigned"
}

variable "environment" {
  description = <<-EOT
    Environment name, used for the Environment tag and resource naming.

    NO DEFAULT, DELIBERATELY. A default of "prod" would silently tag every
    deploy-test as production — corrupting cost allocation and making a throwaway
    stack indistinguishable from the real ledger in the console and the bill.

      "sit"  -> system integration test   (Octopus environment SIT)
      "uat"  -> user acceptance test      (Octopus environment UAT)
      "prod" -> production                (Octopus environment PROD)

    Three environments as of 2026-09-09. All run in af-south-1 so a lower
    environment exercises the real region -- endpoint availability, per-AZ
    instance types and AZ IDs all differ by region, and a test in another region
    does not prove them.

    EACH ENVIRONMENT HAS ITS OWN CIDR ALLOCATION and therefore its own
    network-handover.auto.tfvars. They are NOT interchangeable: applying with
    the wrong pair of files points a cluster at another environment's subnets.
  EOT
  type        = string

  validation {
    condition     = contains(["prod", "uat", "sit"], var.environment)
    error_message = "environment must be \"sit\", \"uat\" or \"prod\"."
  }
}

# -----------------------------------------------------------------------------
# REGION
# -----------------------------------------------------------------------------
variable "primary_region" {
  description = <<-EOT
    AWS region where the validator set runs. Single-region by design (DR removed).

    NO DEFAULT, DELIBERATELY. This is a ledger for a financial institution and the
    region carries data-residency consequences, so it must be an explicit, reviewed
    choice in the environment tfvars rather than something a forgotten variable
    silently decides.

      environments/sit/*.tfvars  -> af-south-1  (system integration test)
      environments/uat/*.tfvars  -> af-south-1  (user acceptance test)
      environments/prod/*.tfvars -> af-south-1  (production)

    All three environments are af-south-1 as of 2026-09-04. af-south-1 is an OPT-IN
    region: enable it on the account before anything provisions. It also costs
    ~31% more than us-east-1, so the per-run cost guardrail buys fewer hours.

    Switching region is a tfvars change, NOT a code change — but `az_ids` must
    change with it (AZ IDs are region-scoped) and the target region must pass
    scripts/preflight/verify-region.sh first.
  EOT
  type        = string
}

# -----------------------------------------------------------------------------
# EKS (stage 1)
# -----------------------------------------------------------------------------
variable "kubernetes_version" {
  description = "EKS control plane Kubernetes version. Default 1.35 (latest well-soaked stable as of 2026-06; 1.36 also available but two weeks old). Upgrade deliberately via the cluster-upgrade runbook. Fallback ladder on compatibility issues: 1.35 -> 1.34 -> ..."
  type        = string
  default     = "1.35"
}

# H10: pin the EKS core addons (resolve-then-pin). Empty = EKS default-for-cluster-
# version (current behavior); set to explicit versions for prod reproducibility and
# so a cluster-version bump does not silently move them. Sequence addon upgrades as
# their own reviewed step, never bundled with a kubernetes_version bump.
variable "addon_versions" {
  description = "H10: pinned EKS core addon versions {vpc_cni, coredns, kube_proxy}. Empty string = EKS default-for-cluster-version."
  type = object({
    vpc_cni    = optional(string, "")
    coredns    = optional(string, "")
    kube_proxy = optional(string, "")
  })
  default = {}
}

variable "ebs_csi_addon_version" {
  description = "H10: pinned aws-ebs-csi-driver addon version. Empty = EKS default-for-cluster-version."
  type        = string
  default     = ""
}

# H6/H10: enable the VPC CNI NetworkPolicy agent so the besu-node NetworkPolicies
# enforce. Pair with network_policy.enabled (besu chart). Default false (opt-in).
variable "enable_network_policy" {
  description = "Enable the VPC CNI NetworkPolicy agent (H6). Pair with network_policy.enabled in the besu module. Default false."
  type        = bool
  default     = false
}

variable "worker_node_count" {
  description = "Desired number of worker nodes. Default 6 (2 per AZ across 3 AZs) hosts 4 validators + 2 bootnodes + RPC + monitoring with validators on distinct nodes/AZs."
  type        = number
  default     = 6

  validation {
    # H12: condition now matches the message (was >= 2). 4 validators need >= 4
    # nodes to land on distinct nodes/AZs (a node loss must not drop 2 validators).
    condition     = var.worker_node_count >= 4
    error_message = "worker_node_count must be >= 4 to host the validator set on distinct nodes."
  }
}

variable "worker_node_min" {
  description = "Minimum worker nodes for the cluster autoscaler."
  type        = number
  default     = 6
}

variable "worker_node_max" {
  description = "Maximum worker nodes the cluster autoscaler may scale to (e.g. when adding RPC nodes for more participants)."
  type        = number
  default     = 10
}

variable "validator_instance_type" {
  description = "EC2 instance type for worker nodes hosting Besu. m6i.xlarge (4 vCPU / 16 GiB) is a sensible production default."
  type        = string
  default     = "m6i.xlarge"
}

variable "node_volume_size_gib" {
  description = "EBS gp3 volume size (GiB) for the node root/data volume. The chain grows over time; allowVolumeExpansion is enabled so this can be raised later."
  type        = number
  default     = 100
}

variable "storage_reclaim_policy" {
  description = "Reclaim policy for the gp3 StorageClass. PROD must be 'Retain' (keeps chain data if a PVC is deleted). NON-PROD uses 'Delete' so test teardown leaves no orphaned volumes billing."
  type        = string
  default     = "Retain"

  validation {
    condition     = contains(["Retain", "Delete"], var.storage_reclaim_policy)
    error_message = "storage_reclaim_policy must be 'Retain' or 'Delete'."
  }
}

variable "deploy_in_cluster_resources" {
  description = <<-EOT
    Whether Terraform should create resources that talk to the KUBERNETES API
    (the gp3 StorageClass and the Secrets Store CSI Helm release).

    Set FALSE when running `terraform apply` from OUTSIDE the VPC (e.g. a
    laptop) against the private EKS endpoint — those in-cluster resources would
    time out. The AWS-layer resources (VPC, EKS, IAM, EBS CSI addon) still apply
    fine. This is the right setting for a laptop-based Stage-1 foundation apply.

    Set TRUE when running from INSIDE the VPC (an SSM/CI runner in a private
    subnet — the real deployment pattern from CLAUDE.md stage 3), so the
    in-cluster resources get created against the reachable private endpoint.
  EOT
  type        = bool
  default     = true
}

variable "eks_public_access" {
  description = "Whether the EKS API server endpoint is publicly reachable. For a fully-private network this MUST be false; access the API via private networking / bastion / VPN."
  type        = bool
  default     = false
}

variable "eks_public_access_cidrs" {
  description = "If eks_public_access is true (NOT recommended), restrict API access to these CIDRs. Ignored when eks_public_access is false."
  type        = list(string)
  default     = []

  validation {
    # H12(d): reject not just the exact 0.0.0.0/0 // ::/0 but every near-open range. Each entry must
    # be a WELL-FORMED CIDR with prefix >= /8 — so /1../7 (which expose a large slice of the internet)
    # and malformed values are rejected too, not just the literal "0.0.0.0/0" string.
    condition     = alltrue([for c in var.eks_public_access_cidrs : can(cidrhost(c, 0)) && try(tonumber(split("/", c)[1]) >= 8, false)])
    error_message = "eks_public_access_cidrs entries must be valid CIDRs with prefix >= /8 (rejects 0.0.0.0/0, ::/0 and near-open /1../7 ranges that expose the EKS API to a large slice of the internet)."
  }
}

# -----------------------------------------------------------------------------
# BESU / CHAIN (later stages — declared now for schema stability)
# -----------------------------------------------------------------------------
variable "besu_version" {
  description = "Besu release tag to deploy (e.g. \"26.6.1\", the latest stable as of 2026-06). Leave empty to have the build resolve the latest release tag from besu-eth/besu and then PIN it; never run a floating 'latest' in production. Deployed as the official Besu Docker image, so the host Java 25+ requirement does not apply (the image bundles its JRE)."
  type        = string
  default     = ""
}

# H11: QBFT 25<->26 wire-compat flag (--Xbft-legacy-protocol-encoding). Default false
# (fresh 26.x deploys don't need it). The rolling upgrade script sets it via --set for a
# mixed-version window; only relevant to a first-create apply here.
variable "bft_legacy_protocol_encoding" {
  description = "Append --Xbft-legacy-protocol-encoding (QBFT 25<->26 mixed-version wire-compat). Keep false for fresh single-version deploys."
  type        = bool
  default     = false
}

# H23: RPC DNS-rebinding + CORS scoping (were hardcoded "*").
variable "rpc_host_allowlist" {
  description = "Besu --host-allowlist on every RPC listener. Default \"*\" preserves the verified access path; scope to the RPC SAN / service DNS at go-live."
  type        = string
  default     = "*"
}

variable "rpc_cors_origins" {
  description = "Besu --rpc-http-cors-origins on every RPC listener. Default \"none\" — all pools are server-to-server or mTLS; the browser never calls Besu directly."
  type        = string
  default     = "none"
}

variable "chain_id" {
  description = "Network chain ID. Choose a value > 0 not used by public networks (chain_id is the EIP-155 replay-protection domain; 0 disables it)."
  type        = number
  default     = 0

  validation {
    # H12: must be > 0 (0 disables EIP-155 replay protection) and not a well-known
    # public network ID (avoid cross-chain replay confusion). The default 0 fails
    # here on purpose — set a real chain_id in the env tfvars.
    condition = var.chain_id > 0 && !contains(
      [1, 3, 4, 5, 10, 56, 100, 137, 250, 8453, 17000, 42161, 43114, 11155111],
    var.chain_id)
    error_message = "chain_id must be > 0 and not a well-known public network ID (1/3/4/5/10/56/100/137/250/8453/17000/42161/43114/11155111)."
  }
}

variable "besu_namespace" {
  description = "Kubernetes namespace for all Besu workloads. Must match the namespace the IRSA trust policy is scoped to (modules/iam)."
  type        = string
  default     = "besu"
}

variable "rpc_node_count" {
  description = "Number of JSON-RPC nodes (non-validating) serving the SWIFT-facing endpoint. >=2 in prod for HA behind the NLB; 1 is fine for a non-prod smoke test."
  type        = number
  default     = 2

  validation {
    condition     = var.rpc_node_count >= 1 && var.rpc_node_count <= 6
    error_message = "rpc_node_count must be between 1 and 6."
  }
}

variable "besu_data_volume_size_gib" {
  description = "Size (GiB) of the per-node EBS gp3 data PVC that holds the chain database. Grows over time; the StorageClass allows expansion. Prod default 100; non-prod uses a small disk."
  type        = number
  default     = 100
}

variable "qbft_block_period_seconds" {
  description = "QBFT block period in seconds. Lower = faster blocks but more sensitive to latency."
  type        = number
  default     = 5

  validation {
    # H12: >= 1. A 0 block period yields an invalid/degenerate genesis + consensus config.
    condition     = var.qbft_block_period_seconds >= 1
    error_message = "qbft_block_period_seconds must be >= 1."
  }
}

variable "validator_count" {
  description = "Initial QBFT validator count. 4 satisfies N=3F+1 (tolerates 1 failure)."
  type        = number
  default     = 4

  validation {
    # H12: QBFT needs N = 3F+1 with N >= 4 (tolerates F >= 1). A count that is not
    # 3F+1 (e.g. 5, 6) wastes a node or gives no extra fault tolerance; < 4 tolerates
    # zero faults and halts on the single validator loss the rolling upgrades assume.
    condition     = var.validator_count >= 4 && (var.validator_count - 1) % 3 == 0
    error_message = "validator_count must be >= 4 and of the form 3F+1 (4, 7, 10, 13, ...) so QBFT tolerates F>=1 failures."
  }
}

variable "bootnode_count" {
  description = "Number of bootnodes. 2 gives redundant peer-discovery seeds without consuming validator slots. Drives the besu-node-bootnode-* secret containers (stage 2) and the bootnode StatefulSet (stage 3)."
  type        = number
  default     = 2

  validation {
    condition     = var.bootnode_count >= 1 && var.bootnode_count <= 5
    error_message = "bootnode_count must be between 1 and 5."
  }
}

variable "use_provided_validator_keys" {
  description = "If true, validator private keys are read from validator_private_keys (and imported to Secrets Manager). If false, keys are generated randomly."
  type        = bool
  default     = false
}

variable "validator_private_keys" {
  description = "List of validator private keys, used ONLY when use_provided_validator_keys is true. Provide via a gitignored secrets tfvars, never commit."
  type        = list(string)
  default     = []
  sensitive   = true
}

# H2 (re-genesis guard): keep false for every normal apply. When false the genesis
# Job refuses to overwrite an existing besu-genesis ConfigMap, so a routine apply can
# never republish a mismatched genesis.json and brick the chain. Set true ONLY for a
# deliberate, destructive re-genesis, and only AFTER wiping the node-key secrets +
# validator PVCs (otherwise the new genesis hash will not match the old chain data).
variable "allow_regenesis" {
  description = "DANGER: allow the genesis Job to (re)publish genesis over an existing besu-genesis ConfigMap. Default false. Only true for an intentional, destructive re-genesis after wiping node-key secrets + validator PVCs."
  type        = bool
  default     = false
}

# -----------------------------------------------------------------------------
# PERMISSIONING (later stages)
# -----------------------------------------------------------------------------
variable "node_permissioning_mode" {
  # "local" (file-based permissions_config.toml) is the only supported mode: Besu
  # removed smart-contract (on-chain) permissioning in 25.6.0 (F17), so the former
  # 'onchain' arm was dropped with the C8 tombstone removal.
  description = "Node (P2P) permissioning: 'local' (file-based, the only supported mode)."
  type        = string
  default     = "local"

  validation {
    condition     = contains(["local"], var.node_permissioning_mode)
    error_message = "node_permissioning_mode must be 'local' (the on-chain mode was removed in Besu 25.6.0 — C8/F17)."
  }
}

variable "account_permissioning_mode" {
  # Account (transaction-sender) permissioning. Values:
  #   "off"   — NOT enforced (default). Any account may transact.
  #   "local" — FILE-BASED account allowlist (C6, implemented 2026-07-05): Besu reads
  #             accounts-allowlist from the besu-account-allowlist ConfigMap via
  #             --permissions-accounts-config-file on every enforcing node. Deny-by-
  #             default — you MUST seed permissioning_admin_account and/or
  #             initial_account_allowlist (an empty allowlist denies every sender; a
  #             render-time preflight blocks that). Onboard more accounts later without
  #             re-genesis via scripts/permissioning/add-account.sh.
  # The former "onchain" mode was REMOVED (C8): Besu dropped smart-contract
  # permissioning in 25.6.0 (F17, CHANGELOG 25.6.0 / PR hyperledger/besu#8597), so
  # it could never run on our pinned version. History: docs/explained/02 §2.5.
  description = "Account permissioning: 'off' (default, not enforced) | 'local' (file-based accounts-allowlist, C6)."
  type        = string
  default     = "off"

  validation {
    condition     = contains(["off", "local"], var.account_permissioning_mode)
    error_message = "account_permissioning_mode must be 'off' or 'local' (the 'onchain' mode was removed in Besu 25.6.0 — C8/F17)."
  }
}

variable "permissioning_admin_account" {
  description = "Admin account address: alloc'd a genesis balance (F20) and, when account_permissioning_mode=local, seeded into the account allowlist as the first authorized sender (C6). Unused while account permissioning is off."
  type        = string
  default     = ""

  validation {
    # H12: empty (unused) OR a valid 20-byte 0x-hex address — a malformed admin
    # address silently produces a genesis/allowlist that never authorizes the sender.
    condition     = var.permissioning_admin_account == "" || can(regex("^0x[0-9a-fA-F]{40}$", var.permissioning_admin_account))
    error_message = "permissioning_admin_account must be empty or a 20-byte 0x-prefixed hex address (^0x[0-9a-fA-F]{40}$)."
  }
}

variable "initial_account_allowlist" {
  description = "Operational signing account addresses to seed into the account allowlist (in addition to the admin account) when account_permissioning_mode=local. Each is also alloc'd a genesis balance so it can transact from block 0 (F20)."
  type        = list(string)
  default     = []

  validation {
    # H12: every entry must be a valid 20-byte 0x-hex address.
    condition     = alltrue([for a in var.initial_account_allowlist : can(regex("^0x[0-9a-fA-F]{40}$", a))])
    error_message = "every initial_account_allowlist entry must be a 20-byte 0x-prefixed hex address (^0x[0-9a-fA-F]{40}$)."
  }
}

# F20 (deploy-test 2026-06-29): addresses alloc'd a genesis BALANCE so they can
# ORIGINATE transactions on the zero-gas chain. This is independent of permissioning:
# on a min-gas-price=0 / zeroBaseFee chain a tx from a zero-balance account is NOT
# mined, so any tx originator (a SWIFT signing account, or the app's signer EOA) must
# be funded here even when account_permissioning_mode="off". Provide the addresses in
# the gitignored prod tfvars.
variable "genesis_funded_accounts" {
  description = "Account addresses to alloc a genesis balance (tx originators on the zero-gas chain; decoupled from permissioning). See F20."
  type        = list(string)
  default     = []

  validation {
    # H12: every funded address must be a valid 20-byte 0x-hex address.
    condition     = alltrue([for a in var.genesis_funded_accounts : can(regex("^0x[0-9a-fA-F]{40}$", a))])
    error_message = "every genesis_funded_accounts entry must be a 20-byte 0x-prefixed hex address (^0x[0-9a-fA-F]{40}$)."
  }
}

# H8: the application's signer EOA address. The root UNIONS it into
# initial_account_allowlist AND genesis_funded_accounts, so under
# account_permissioning_mode="local" the signer is both authorized (its tx is
# accepted) and funded (can transact on the zero-gas chain) on a fresh deploy — with
# no brittle hand-pasting. Supply it in the gitignored tfvars. Empty = no app.
variable "app_signer_account" {
  description = "H8: app signer EOA address. Auto-added to the account allowlist + funded accounts. Empty when no app is deployed."
  type        = string
  default     = ""

  validation {
    condition     = var.app_signer_account == "" || can(regex("^0x[0-9a-fA-F]{40}$", var.app_signer_account))
    error_message = "app_signer_account must be empty or a 20-byte 0x-prefixed hex address (^0x[0-9a-fA-F]{40}$)."
  }
}

# -----------------------------------------------------------------------------
# mTLS / CA (later stages)
# -----------------------------------------------------------------------------
variable "ca_mode" {
  description = "Certificate authority for mTLS: empty string = self-managed openssl/tls-provider CA (near-zero cost); 'aws' = AWS Private CA (managed, ~$400/mo)."
  type        = string
  default     = ""

  validation {
    condition     = var.ca_mode == "" || var.ca_mode == "aws"
    error_message = "ca_mode must be empty (self-managed) or 'aws' (AWS Private CA)."
  }
}

variable "ca_common_name" {
  description = "Subject common name (CN) of the self-managed CA certificate. Used only when ca_mode is the self-managed default."
  type        = string
  default     = "Besu RPC mTLS Root CA"
}

variable "ca_organization" {
  description = "Subject organization (O) of the CA certificate."
  type        = string
  default     = "Besu AWS Network"
}

variable "ca_validity_days" {
  description = "Validity period (days) of the self-managed CA certificate. Default 3650 (10 years) for a long-lived private root."
  type        = number
  default     = 3650
}

variable "server_cert_ca_override" {
  description = "If SWIFT (or another counterparty) mandates a specific CA for YOUR server certificate, set its reference here. Empty = use ca_mode for the server cert too."
  type        = string
  default     = ""
}

variable "rpc_auth_mode" {
  description = "RPC authorization mode: 'tls-only' (mTLS gates connection) or 'tls-plus-method' (mTLS + per-user JWT method scoping). Changing it triggers a rolling restart of RPC nodes."
  type        = string
  default     = "tls-plus-method"

  validation {
    condition     = contains(["tls-only", "tls-plus-method"], var.rpc_auth_mode)
    error_message = "rpc_auth_mode must be 'tls-only' or 'tls-plus-method'."
  }
}

variable "rpc_dual_pool" {
  description = "If true, run two RPC pools (tls-only and tls-plus-method) so individual clients can be moved between layers with zero restart."
  type        = bool
  default     = false
}

# -----------------------------------------------------------------------------
# In-VPC EC2 Runner (stage 3)
# -----------------------------------------------------------------------------
# NOTE (C1): `deploy_runner` and `runner_instance_type` were REMOVED — the runner
# now lives in its own root (terraform/runner/), so the chain no longer gates or
# sizes it. This eliminates the F4/F5 flag traps (a chain apply can't touch the
# runner). The runner's instance type is set in terraform/runner/variables.tf.

# --- Runner code + config delivery (F15/F16) ---------------------------------
# The runner lives in a PRIVATE subnet in a VPC with NO EGRESS, so it can neither
# install packages nor clone GitHub — both HANG until timeout rather than failing,
# and the runner is the only path to the private EKS API. D-21: its toolchain and
# source arrive as two S3 objects, pushed from the laptop by
# scripts/runner/push-runner-bundle.sh and pulled over the S3 gateway endpoint;
# the gitignored env config arrives separately through Secrets Manager
# (scripts/runner/push-deploy-config.sh). Both destinations are created by this
# root during the AWS-layer apply, so they exist before the runner boots.
#
# There is deliberately NO GitHub token variable. The PAT path was removed with
# the clone: it needed internet the VPC does not have, and it generated findings
# of its own (F28 stale-token-after-rotation, H18 keeping it out of git argv and
# error logs, H39 rotate-the-PAT). Removing the credential removes the class.

# -----------------------------------------------------------------------------
# SECRETS MANAGER (stage 2)
# -----------------------------------------------------------------------------
variable "secret_recovery_window_days" {
  description = "AWS Secrets Manager recovery window on delete. PROD: 7-30 (a deleted secret is recoverable for this many days). NON-PROD: 0 to force-delete immediately so test teardown leaves nothing billing and a re-apply does not collide with a secret still 'scheduled for deletion'."
  type        = number
  default     = 30

  validation {
    condition     = var.secret_recovery_window_days == 0 || (var.secret_recovery_window_days >= 7 && var.secret_recovery_window_days <= 30)
    error_message = "secret_recovery_window_days must be 0 (force delete) or between 7 and 30 (AWS-allowed recovery window)."
  }
}

# -----------------------------------------------------------------------------
# KMS — customer CMK for validator/node key custody (C12, FIPS 140-2 L3 path B)
# -----------------------------------------------------------------------------
# Encrypt the validator/bootnode/node-identity key secrets (and the self-managed
# CA private key) at rest under a CUSTOMER-managed KMS CMK — FIPS 140-3 Level 3
# validated hardware (CMVP #4884), under a key policy WE control + a per-decrypt
# CloudTrail audit trail. This is the "at-rest custody" reading of the FIPS
# requirement (auditor doc §9 / Option B); it does NOT change how Besu signs.
# See docs/fips-140-l3-validator-key-management-analysis.md + backlog C12.
variable "enable_node_key_cmk" {
  description = "C12: encrypt the Besu node-key (validator/bootnode/rpc/app-rpc/explorer-rpc) + CA-private-key secrets with a customer-managed KMS CMK, and scope kms:Decrypt to the pod/genesis IRSA roles. false = the AWS-managed aws/secretsmanager key (baseline). Recommended true for prod (FIPS-L3 at-rest custody)."
  type        = bool
  default     = false
}

# H7: envelope-encrypt Kubernetes Secrets in etcd with a dedicated customer CMK
# (distinct from the C12 node-key CMK). One-way once enabled on a cluster (AWS does
# not allow removing an encryption provider); set at creation for fresh applies.
variable "enable_secrets_encryption" {
  description = "H7: envelope-encrypt K8s Secrets in etcd with a dedicated CMK. Keep true for prod. One-way once enabled on a cluster; disable only for throwaway deploy-tests where the extra CMK is unwanted."
  type        = bool
  default     = true
}

# H20: customer CMK for DATA-AT-REST (chain-data PVCs + node root EBS). Empty =
# AWS-managed keys (current behavior). Supply a dedicated data CMK for prod whose
# policy permits the EBS service + the node/autoscaling role + the EBS CSI IRSA role.
# (RPC/JWT secrets, CloudWatch log groups, and SNS remain a documented follow-up.)
variable "data_cmk_arn" {
  description = "H20: customer CMK ARN for at-rest encryption of chain-data PVCs + node EBS. Empty = AWS-managed keys. The CMK policy must permit EBS + node role + EBS CSI IRSA."
  type        = string
  default     = ""
}

variable "kms_deletion_window_days" {
  description = "C12: waiting period (days) before the node-key CMK is actually deleted after `terraform destroy` schedules it. PROD: 30 (recovery safety). DEPLOY-TEST: 7 (minimum) so teardown lingers less. KMS bills the key (~$1/mo) until the window elapses."
  type        = number
  default     = 30

  validation {
    condition     = var.kms_deletion_window_days >= 7 && var.kms_deletion_window_days <= 30
    error_message = "kms_deletion_window_days must be between 7 and 30 (AWS-allowed CMK deletion window)."
  }
}

variable "enable_kms_data_events" {
  description = "C12: RETAINED no-op (F31, 2026-07-05). KMS Decrypt/GenerateDataKey are CloudTrail MANAGEMENT events (AWS::KMS::Key is not a valid data-event resources.type — PutEventSelectors rejects it), so the base CloudTrail (enable_cloudtrail) ALREADY logs every decrypt on the CMK. Kept only so existing tfvars validate."
  type        = bool
  default     = false
}

# -----------------------------------------------------------------------------
# RPC ACCESS / mTLS EDGE (stage 4)
# -----------------------------------------------------------------------------
variable "enable_rpc_ingress" {
  description = "Create the internal NLB edge (NLB + target group + listener + SG) that fronts the RPC nodes for the SWIFT SIPN path. AWS-layer (applies from anywhere); the in-cluster TargetGroupBinding that registers pods is gated by deploy_in_cluster_resources."
  type        = bool
  default     = true
}

variable "rpc_mtls_enabled" {
  description = "Terminate mTLS natively at Besu RPC (PKCS12 keystore + CA truststore + client-auth). The keystore/truststore are issued by scripts/pki/issue-server-cert.sh into Secrets Manager BEFORE the RPC nodes start. Keep true for the SWIFT-facing design."
  type        = bool
  default     = true
}

# -----------------------------------------------------------------------------
# SWIFT / SIPN ACCESS (later stages)
# -----------------------------------------------------------------------------
variable "swift_sipn_allowed_cidrs" {
  description = "SWIFT SIPN source CIDR ranges permitted to reach the RPC endpoint. Supplied from SWIFT connectivity documentation / your service provider."
  type        = list(string)
  default     = []

  validation {
    # H12(d): the SWIFT RPC edge is a scoped SIPN path — each entry must be a well-formed CIDR with
    # prefix >= /8, so /0 AND near-open /1../7 ranges (and malformed values) are all rejected.
    condition     = alltrue([for c in var.swift_sipn_allowed_cidrs : can(cidrhost(c, 0)) && try(tonumber(split("/", c)[1]) >= 8, false)])
    error_message = "swift_sipn_allowed_cidrs entries must be valid CIDRs with prefix >= /8 (rejects 0.0.0.0/0, ::/0 and near-open /1../7 ranges — the SWIFT edge is a scoped SIPN path, never open)."
  }
}

variable "swift_rpc_hostname" {
  description = "Hostname SWIFT targets for RPC (becomes part of the connection pack)."
  type        = string
  default     = ""
}

variable "swift_rpc_port" {
  description = "Port SWIFT targets for RPC."
  type        = number
  default     = 8545
}

variable "swift_permitted_methods" {
  description = "Explicit allowlist of JSON-RPC methods SWIFT may call. Excludes admin/debug/perm/txpool/miner."
  type        = list(string)
  default     = ["eth_call", "eth_sendRawTransaction", "eth_getLogs", "eth_blockNumber", "net_version", "web3_clientVersion"]
}

# -----------------------------------------------------------------------------
# APP LAYER HOOKS (later stages)
# -----------------------------------------------------------------------------
variable "enable_app_privatelink" {
  description = "Legacy hook: expose the SWIFT NLB as a PrivateLink endpoint service. Stage 8 (A′) does NOT use this — the app consumes the dedicated app-rpc edge (enable_app_rpc) instead. Leave false unless a private consumer needs the SWIFT mTLS NLB."
  type        = bool
  default     = false
}

# -----------------------------------------------------------------------------
# STAGE 8 — APP-RPC POOL (A′: separate app-facing RPC pool + edge)
# -----------------------------------------------------------------------------
variable "app_rpc_count" {
  description = "Number of app-rpc pool nodes (besu-app-rpc-1..J) inside the chain cluster. 0 = app layer not deployed. Per the mirror rule, prod and non-prod share the topology; non-prod just runs fewer."
  type        = number
  default     = 0
}

variable "explorer_rpc_count" {
  description = "Stage 9: number of explorer-rpc pool nodes (besu-explorer-rpc-1..E) inside the chain cluster — the dedicated ClusterIP-only DEBUG/TRACE RPC pool Blockscout indexes from. 0 = explorer not deployed. Mirror rule: same topology in both envs, non-prod runs fewer."
  type        = number
  default     = 0
}

# --- Stage 9: Blockscout explorer --------------------------------------------
variable "enable_blockscout" {
  description = "Deploy the in-cluster Blockscout explorer (indexes the explorer-rpc pool). Requires explorer_rpc_count > 0. In-cluster, so it only applies when deploy_in_cluster_resources=true (from the In-VPC EC2 Runner)."
  type        = bool
  default     = false
}

variable "blockscout_network_name" {
  description = "Display name Blockscout shows for the network."
  type        = string
  default     = "Besu (private)"
}

variable "blockscout_access_host" {
  description = "host:port the BROWSER uses to reach the explorer = the local end of the port-forward to the nginx proxy. NEXT_PUBLIC_API_HOST/APP_HOST are baked from this (same-origin, no CORS). Must match `kubectl port-forward svc/blockscout-proxy <thisPort>:80`."
  type        = string
  default     = "localhost:4000"
}

variable "blockscout_pg_storage_size_gib" {
  description = "gp3 PVC size for Blockscout's Postgres. Mirror rule: same component both envs; non-prod smaller. Re-indexable, so non-prod can be small."
  type        = number
  default     = 10
}

variable "enable_app_rpc" {
  description = "Create the separate app-rpc edge (own internal NLB + HTTP/WS target groups + dedicated PrivateLink service). The app VPC consumes app_rpc_privatelink_service_name."
  type        = bool
  default     = false
}

variable "app_rpc_http_port" {
  description = "App-rpc HTTPS JSON-RPC port (Besu server-TLS terminated)."
  type        = number
  default     = 8545
}

variable "app_rpc_ws_port" {
  description = "App-rpc WSS port (eth_subscribe for the read-only event listener)."
  type        = number
  default     = 8546
}

variable "app_rpc_ws_enabled" {
  description = "Expose the WS plane on the app-rpc pool + edge."
  type        = bool
  default     = true
}

variable "app_rpc_tls_enabled" {
  description = "Server-side TLS (https/wss) on the app-rpc pool (CA-signed server keystore; no client auth)."
  type        = bool
  default     = true
}

variable "app_rpc_auth_enabled" {
  description = "Require JWT auth on the app-rpc pool (the app mints tokens; Besu verifies)."
  type        = bool
  default     = true
}

variable "app_rpc_allowed_cidrs" {
  description = "CIDRs allowed to reach the app-rpc NLB (the app VPC CIDR; traffic arrives via PrivateLink)."
  type        = list(string)
  default     = []

  validation {
    # H12(d): the app-rpc edge is a scoped PrivateLink path — each entry must be a well-formed CIDR
    # with prefix >= /8, so /0 AND near-open /1../7 ranges (and malformed values) are all rejected.
    condition     = alltrue([for c in var.app_rpc_allowed_cidrs : can(cidrhost(c, 0)) && try(tonumber(split("/", c)[1]) >= 8, false)])
    error_message = "app_rpc_allowed_cidrs entries must be valid CIDRs with prefix >= /8 (rejects 0.0.0.0/0, ::/0 and near-open /1../7 ranges — app-rpc arrives via PrivateLink, never open)."
  }
}

variable "ops_rpc_enabled" {
  description = "Enable the validator-internal ops RPC listener (QBFT/admin via kubectl port-forward; never NLB-fronted)."
  type        = bool
  default     = false
}

# H6: JWT pubkey secret for the ops listener (RS256). Empty = no JWT. When empty
# AND ops_rpc_enabled=true, the chart FAILS render unless ops_rpc_allow_no_jwt=true.
variable "ops_rpc_jwt_pubkey_secret_name" {
  description = "Secrets Manager name of the ops-listener JWT verification public key. Empty = no JWT (requires ops_rpc_allow_no_jwt=true when ops is enabled)."
  type        = string
  default     = ""
}

# H6: accept the ops listener without a JWT (ClusterIP + port-forward + NetworkPolicy
# trust only). Keep false and provide a JWT for prod; set true to keep the historical
# no-JWT model. Only relevant when ops_rpc_enabled=true.
variable "ops_rpc_allow_no_jwt" {
  description = "Allow the ops listener to run without a JWT pubkey. Keep false for prod (set a JWT); true accepts ClusterIP+port-forward-only protection."
  type        = bool
  default     = false
}

# H6: per-role NetworkPolicy ingress lockdown for the besu-node pods. Disabled by
# default — enforced ONLY when the VPC CNI NetworkPolicy agent is enabled, and the
# client sources must be set per deployment (an incomplete set denies legit RPC).
variable "network_policy" {
  description = "NetworkPolicy config passed to the besu module (H6). Disabled by default; validate on a mock deploy before enabling."
  type = object({
    enabled             = optional(bool, false)
    monitoringNamespace = optional(string, "monitoring")
    rpcClientCidrs      = optional(list(string), [])
    appRpcClientCidrs   = optional(list(string), [])
    explorerClient      = optional(map(string), {})
  })
  default = {}
}

# -----------------------------------------------------------------------------
# OBSERVABILITY (later stages)
# -----------------------------------------------------------------------------
variable "alert_email" {
  description = "Email address that receives Alertmanager/CloudWatch alerts via an SNS topic subscription."
  type        = string
  default     = ""
}

variable "log_retention_days" {
  description = "CloudWatch Logs retention in days for pod and infrastructure logs."
  type        = number
  default     = 90
}

# -----------------------------------------------------------------------------
# OBSERVABILITY (stage 5)
# -----------------------------------------------------------------------------
variable "enable_cloudtrail" {
  description = "Create an account CloudTrail (+S3 bucket) for API audit. Set false to skip (e.g. if the account already has an org trail)."
  type        = bool
  default     = true
}

# H19: gate force_destroy on the CloudTrail audit bucket. true (default, deploy-test)
# allows a clean teardown; set FALSE for prod so `terraform destroy` refuses to wipe
# the forensic record.
variable "cloudtrail_force_destroy" {
  description = "H19: allow destroy to delete a non-empty CloudTrail bucket. true for deploy-tests; FALSE for prod."
  type        = bool
  default     = true
}

variable "cloudtrail_kms_key_arn" {
  description = "H19: customer CMK ARN for CloudTrail bucket SSE-KMS + trail encryption. Empty = SSE-S3 (AES256). CMK policy must permit CloudTrail."
  type        = string
  default     = ""
}

# H13: ELB deletion protection on the SWIFT/app NLBs. false (default) for deploy-tests
# so teardown works; set TRUE for prod (a deleted NLB gets a new DNS name → breaks SWIFT).
# NOTE: `prevent_destroy` on the C12 CMK, node-key secrets, and CloudTrail bucket cannot be
# variable-gated (Terraform requires a literal) — for the long-lived prod chain add
# `lifecycle { prevent_destroy = true }` to those resources directly; the KMS deletion
# window + secrets recovery window + H19 force_destroy=false are the gateable protections.
variable "enable_deletion_protection" {
  description = "H13: ELB deletion protection on the SWIFT/app NLBs. false for deploy-tests; true for prod."
  type        = bool
  default     = false
}

# H5 (residual closure): attach a permissions BOUNDARY to every IAM role this
# stack creates, so the in-VPC deploy runner — which must be able to create roles
# — cannot create one that escalates to account admin. See iam-boundary.tf for the
# full rationale. Default TRUE: the secure posture is the default; turning it off
# re-opens the escalation path the 2026-07-06 whitebox pentest found.
variable "enable_iam_permissions_boundary" {
  description = "H5: attach a permissions boundary to every stack-created IAM role (caps iam:*/organizations:*/account:*). Keep true."
  type        = bool
  default     = true
}

# Bring-your-own boundary: set this to an organisation-managed policy ARN and the
# stack attaches THAT instead of creating its own. It must still permit what the
# stack's roles legitimately do (EKS/EC2/ELB/KMS/S3/Secrets Manager/logs/SNS/ECR)
# or the cluster will break. Empty = this stack creates and manages the boundary.
variable "iam_permissions_boundary_arn" {
  description = "H5: ARN of an existing permissions-boundary policy to attach to stack roles. Empty = create `<name_prefix>-role-boundary`."
  type        = string
  default     = ""

  validation {
    condition     = var.iam_permissions_boundary_arn == "" || can(regex("^arn:aws[a-z-]*:iam::[0-9]{12}:policy/", var.iam_permissions_boundary_arn))
    error_message = "iam_permissions_boundary_arn must be empty or a customer-managed IAM policy ARN (arn:aws:iam::<account>:policy/<name>)."
  }
}

variable "grafana_admin_password" {
  description = "Grafana admin password for the non-prod test. Prod should pull this from Secrets Manager, not tfvars."
  type        = string
  default     = ""
  sensitive   = true
}

# =============================================================================
# Container images — the air-gapped supply chain (CLAUDE.md §5.2)
# =============================================================================
# In this VPC there is NO egress. Every image must come from our private ECR
# registry (CT-3), and an image
# that does not is not a clean failure: the pull routes to a public IP with no
# path out and HANGS until timeout, surfacing as ImagePullBackOff with nothing
# naming the registry as the cause.
#
# Images are declared ONCE, here, as data. Nothing else in the repository names
# a registry, so adding a component means adding a row -- not hunting through
# chart values for a hardcoded string, which is how stats, visualizer and nginx
# came to be unreachable in an air-gapped VPC without anyone noticing.
# =============================================================================

variable "registry_host" {
  description = <<-EOT
    Private registry that mirrors every upstream, e.g.
    "111122223333.dkr.ecr.af-south-1.amazonaws.com" (CT-3).

    ECR is a registry, not a proxy: nothing appears here on demand. Images are
    copied in deliberately from outside the VPC, digest-preserving, by
    scripts/supply-chain/. ECR pull-through cache CANNOT be used -- its first
    pull requires an internet route, which this VPC does not have (D-17).

    Empty means pull from each image's own upstream host -- correct ONLY where
    there is egress. Leave it empty at your peril in the real VPC: the failure
    is a hang, not an error.
  EOT
  type        = string
  default     = ""
}

variable "registry_repo_prefixes" {
  description = <<-EOT
    Upstream host -> path prefix inside the registry, keeping each upstream in
    its own repository namespace:

      { "docker.io" = "docker-hub", "ghcr.io" = "ghcr" }
        => <acct>.dkr.ecr.<region>.amazonaws.com/docker-hub/hyperledger/besu:26.6.1

    ECR repository names permit '/', so upstream paths map 1:1 under the prefix.
    Leave empty to mirror upstream paths with no prefix at all. Only consulted
    when registry_host is set.
  EOT
  type        = map(string)
  default     = {}
}

variable "container_images" {
  description = <<-EOT
    Every image this platform runs. `host` is the UPSTREAM registry, used when
    registry_host is empty and to look up the mirror's path prefix when it is not.

    `digest` pins by content (H38) and wins over `tag` when set. A tag is a
    mutable pointer: re-pulling the same tag can yield different bytes, which in
    a permissioned financial network means a node can come back as software
    nobody reviewed. Resolve digests with scripts/preflight/verify-images.sh.
  EOT
  type = map(object({
    host       = string
    repository = string
    tag        = string
    digest     = optional(string, "")
  }))

  default = {
    besu       = { host = "docker.io", repository = "hyperledger/besu", tag = "26.6.1" }
    tools      = { host = "docker.io", repository = "alpine/k8s", tag = "1.30.13" }
    blockscout = { host = "ghcr.io", repository = "blockscout/blockscout", tag = "9.0.2" }
    frontend   = { host = "ghcr.io", repository = "blockscout/frontend", tag = "v2.3.5" }
    stats      = { host = "ghcr.io", repository = "blockscout/stats", tag = "v2.16.0" }
    visualizer = { host = "ghcr.io", repository = "blockscout/visualizer", tag = "v0.2.1" }
    proxy      = { host = "docker.io", repository = "nginx", tag = "1.27-alpine" }
    postgres   = { host = "docker.io", repository = "postgres", tag = "16-alpine" }
  }

  validation {
    condition     = alltrue([for k, v in var.container_images : v.digest == "" || startswith(v.digest, "sha256:")])
    error_message = "Image digests must be of the form sha256:<64 hex>."
  }

  validation {
    condition     = alltrue([for r in ["besu", "tools", "blockscout", "frontend", "stats", "visualizer", "proxy", "postgres"] : contains(keys(var.container_images), r)])
    error_message = "container_images must define every component: besu, tools, blockscout, frontend, stats, visualizer, proxy, postgres. Removing one does not disable it -- the chart falls back to a hardcoded upstream reference that cannot be pulled in an air-gapped VPC."
  }
}

variable "require_image_digests" {
  description = "Fail the plan unless every image is digest-pinned. Off during bring-up (digests are unknown until the images are mirrored); turn ON for production -- H38."
  type        = bool
  default     = false
}

variable "registry_ca_cert_pem" {
  description = <<-EOT
    PEM of the CA that signed the registry's TLS certificate, installed into
    every node's OS trust store so containerd can pull from it.

    NOT needed for ECR, which presents a publicly-trusted certificate -- set
    registry_cert_publicly_trusted = true instead. Retained for any registry
    fronted by a private CA. Without it such a pull fails with
    x509: certificate signed by unknown authority, surfaced to you as a plain
    ImagePullBackOff that names neither the registry nor the certificate.

    Not a secret — a CA certificate is public by construction — so it is carried
    inline in the launch template rather than fetched at boot. See
    modules/eks/variables.tf:extra_ca_cert_pem for why that ordering matters.
  EOT
  type        = string
  default     = ""
}

variable "registry_cert_publicly_trusted" {
  description = "Assert that registry_host presents a certificate from a CA already in the AMI trust store, so no registry_ca_cert_pem is needed. An explicit opt-out rather than an empty value, so that skipping CA trust is a decision on the record and not an omission."
  type        = bool
  default     = false
}
