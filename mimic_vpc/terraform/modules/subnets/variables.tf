variable "name_prefix" { type = string }
variable "vpc_id" { type = string }
variable "region" { type = string }

variable "subnets" {
  description = "Flat map keyed \"<role>-<az_id>\" => { role, az_id, cidr }. Built in the root locals.tf."
  type = map(object({
    role  = string
    az_id = string
    cidr  = string
  }))
}

variable "lb_subnet_tags" {
  description = "#4 — Kubernetes discovery tags applied to the load-balancer subnets only."
  type        = map(string)
}

variable "gateway_endpoints_created_here" {
  description = "#10 — see root variables.tf."
  type        = bool
}

variable "simulate_central_endpoints" {
  description = "Q-2 — see root variables.tf."
  type        = bool
  default     = false
}

variable "interface_endpoint_services" {
  description = <<-EOT
    The 15 interface endpoints the platform requires. Used ONLY when
    simulate_central_endpoints = true. `eks-auth` is deliberately absent (the
    platform uses IRSA, not Pod Identity) and so is `autoscaling` (no Cluster
    Autoscaler or Karpenter is deployed). If either is ever introduced, add its
    endpoint in the same change.
  EOT
  type        = list(string)
  default = [
    "ssm", "ssmmessages", "ec2messages", # only access path to the runner
    "ec2",                               # EBS CSI volume attach, VPC CNI ENI mgmt
    "ecr.api", "ecr.dkr",                # AWS-owned EKS addon images (#19)
    "sts",                               # IRSA
    "eks",
    "elasticloadbalancing", # AWS Load Balancer Controller
    "secretsmanager",       # Secrets Store CSI driver
    "kms",                  # validator key decryption at pod start
    "logs", "monitoring", "sns",
    "sqs", # event pipeline (SNS FIFO -> SQS FIFO); see EVENT_LISTENER_DESIGN_NOTES §7
  ]
}

variable "tags" {
  type    = map(string)
  default = {}
}

# =============================================================================
# NACL rules (CT-1a, D-29, D-32) — added 2026-10-09 with nacl.tf
# =============================================================================

variable "vpc_cidr" {
  description = "The VPC's primary CIDR. Needed by the NACL rules for the two flows whose counterparty is 'anywhere in the VPC': the interface endpoints (F-5) and the Amazon-provided DNS resolver (F-10)."
  type        = string
}

variable "nacl_mode" {
  description = <<-EOT
    "flows"      — DEFAULT (D-32). Deny by default; permit only requirement
                   #34's F-1..F-10. This is the mode the platform's
                   verify-subnet-rules.sh is written against.
    "permissive" — the pre-2026-10-09 allow-all baseline. Retained for ONE
                   legitimate use: bisecting a connectivity problem to decide
                   whether the NACLs are the cause. Using it otherwise returns
                   the fixture to a state where the platform's checker cannot
                   fail, which is the defect D-32 exists to remove.
    "none"       — create no NACLs at all, so the subnets fall back to the VPC's
                   default NACL. Models a cloud team that uses security groups
                   only (question C), which is a real possible answer.
  EOT
  type        = string
  default     = "flows"

  validation {
    condition     = contains(["flows", "permissive", "none"], var.nacl_mode)
    error_message = "nacl_mode must be flows (default), permissive, or none."
  }
}

variable "nacl_break_flow" {
  description = <<-EOT
    Drop every rule whose flow label CONTAINS this string. The fixture knob that
    proves the platform's verify-subnet-rules.sh detects an ABSENT rule rather
    than merely parsing a present one — the B12 lesson applied to NACLs.

    Each of these produces a distinct, realistic failure:
      "F-1 peer UDP"  discovery dies; statically-configured peers still connect,
                      so the chain LOOKS FINE until something needs discovery
      "F-6"           image pulls stall mid-layer (ECR serves manifests, S3
                      serves bytes)
      "F-5"           every AWS SDK call hangs until timeout — the signature
                      failure of this whole VPC design
      "F-2"           NLB health checks never pass; targets unhealthy forever
                      with nothing naming a rule
  EOT
  type        = string
  default     = ""
}

variable "s3_cidrs" {
  description = <<-EOT
    F-6 — S3's regional prefixes. A NACL CANNOT reference a prefix list, which
    is the trap #34 F-6 names. Empty means the rule falls back to 0.0.0.0/0,
    which is what a real cloud team would most likely do and is therefore the
    faithful default — not a shortcut being hidden. Populate from
    `aws ec2 describe-managed-prefix-lists` to exercise the enumerated form.
  EOT
  type        = list(string)
  default     = []
}

variable "egress_proxy_cidr" {
  description = "F-8 — the prefix the egress proxy VIP lives in (mimic_egress emits it as egress_vpc_cidr). Empty omits the rule, which models the egress ticket not yet being answered."
  type        = string
  default     = ""
}

variable "egress_proxy_port" {
  description = "F-8 — the proxy's CONNECT port."
  type        = number
  default     = 3128
}

variable "sipn_cidr" {
  description = "The prefix SWIFT reaches the RPC NLBs from, over MV-SIPN. Empty falls back to the VPC CIDR, which is what a mimic with no TGW can actually test."
  type        = string
  default     = ""
}

variable "nacl_source_mode" {
  description = <<-EOT
    How tightly each rule names its counterparty — and it is a RULE-BUDGET
    decision, not only a security one.

    AWS allows 20 rules per NACL PER DIRECTION by default (raisable to 40, with
    a documented network-performance caveat). #34's flow table with a per-AZ
    CIDR for every counterparty needs 26 ingress and 30 egress rules on the
    workload subnets — it does NOT fit.

    "summarised" (default) — per-subnet sources on the SERVICE ports (30303,
                  8545-8546, 5432), where narrowing genuinely restricts who may
                  open a connection; the VPC CIDR for the ephemeral RETURN
                  ranges, where narrowing is largely illusory because every port
                  this platform listens on is inside 1024-65535. Fits in 20.
    "narrow"     — per-subnet sources everywhere. Tightest, and what a security
                  review asks for. REQUIRES the quota raised to 40.
  EOT
  type        = string
  default     = "summarised"

  validation {
    condition     = contains(["summarised", "narrow"], var.nacl_source_mode)
    error_message = "nacl_source_mode must be 'summarised' (default, fits the 20-rule limit) or 'narrow' (needs the quota raised to 40)."
  }
}

variable "ledger_subnets_in_use" {
  description = "#28 — true only when a dedicated ledger node group was granted and our pods actually run in the ledger subnets. Under CT-5 the default is FALSE: our pods land in the application subnets, and carrying the ledger peer rules regardless costs 12 rules on the subnets that are already tightest."
  type        = bool
  default     = false
}

variable "nacl_rule_limit" {
  description = "AWS's per-NACL per-direction rule quota. 20 by default; set 40 after raising it. The module FAILS THE PLAN rather than letting AWS reject a rule mid-apply."
  type        = number
  default     = 20
}
