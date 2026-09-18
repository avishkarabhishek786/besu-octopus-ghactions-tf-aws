# =============================================================================
# variables.tf — the `shared` root
# -----------------------------------------------------------------------------
# The network hand-over variables (vpc_id, subnets, route tables, the two
# ownership booleans) are NOT declared here — they live in ../contract/handover.tf,
# which is symlinked into every network-consuming root so all roots read one
# identical contract and run the same eight gates.
# =============================================================================

variable "project_name" {
  description = "Static identifier for the whole system; first element of every resource name and the Project tag."
  type        = string
  default     = "sbsa-besu"
}

variable "environment" {
  description = "Deployment environment (\"sit\" | \"uat\" | \"prod\"), matching the Octopus environment names SIT, UAT and PROD. Drives the Environment tag, so it must NOT default: tagging a deploy-test as \"prod\" corrupts cost allocation and makes a test indistinguishable from production. All three run in af-south-1, each in its own CIDR allocation."
  type        = string

  validation {
    condition     = contains(["prod", "uat", "sit"], var.environment)
    error_message = "environment must be \"sit\", \"uat\" or \"prod\"."
  }
}

variable "deletion_group" {
  description = "UNIQUE-per-deployment id. scripts/maintenance/full-delete.sh targets exactly this value, so a second deployment in the same account is never caught in the blast radius."
  type        = string
}

variable "owner" {
  description = "Team or email accountable for these resources (Owner tag)."
  type        = string
}

variable "cost_center" {
  description = "Finance chargeback code (CostCenter tag)."
  type        = string
}

variable "primary_region" {
  description = <<-EOT
    Region to deploy into. MUST equal the region the network hand-over was
    emitted from — gate 8 enforces this. No default: a root that silently lands
    in the wrong region fails with a confusing timeout rather than a clear error.
  EOT
  type        = string
}

variable "name_prefix_override" {
  description = "Override the derived \"<project>-<environment>\" name prefix. Leave empty to derive it."
  type        = string
  default     = ""
}

# -----------------------------------------------------------------------------
# Interface endpoints (CLAUDE.md §5.1)
# -----------------------------------------------------------------------------
variable "interface_endpoint_services" {
  description = <<-EOT
    AWS service short names to create interface endpoints for, one per AZ in the
    endpoint subnets. The default is the full air-gapped set (15).

    ssm/ssmmessages/ec2messages are the ONLY path to the runner: without them
    there is no way in at all. s3 is absent on purpose — it is a free gateway
    endpoint. eks-auth is excluded (we use IRSA, not Pod Identity) and
    autoscaling is excluded (no Cluster Autoscaler or Karpenter is deployed);
    if either is ever introduced, its endpoint must be added in the same change.

    HARD RULE: every new AWS service used by any workload in this VPC needs its
    own endpoint. A missing one HANGS until timeout rather than erroring, and
    the debugging cost far exceeds the ~$7/mo the endpoint costs.
  EOT
  type        = list(string)
  default = [
    "ssm", "ssmmessages", "ec2messages", # runner access — no substitute
    "ec2", "ecr.api", "ecr.dkr",         # nodes + image pulls
    "sts", "eks", "elasticloadbalancing",
    "secretsmanager", "kms",
    "logs", "monitoring", # Fluent Bit + CloudWatch metrics
    "sns", "sqs",         # Alertmanager + the event pipeline
  ]

  validation {
    condition     = !contains(var.interface_endpoint_services, "s3")
    error_message = "s3 must not be an interface endpoint here — it is created as a FREE gateway endpoint. An interface endpoint for s3 would bill ~$7/mo per AZ for nothing."
  }
}

variable "endpoint_private_dns" {
  description = "Enable private DNS on the interface endpoints so workloads reach AWS services at their normal hostnames with no client configuration. Requires both VPC DNS attributes (gate 1 asserts them)."
  type        = bool
  default     = true
}

# -----------------------------------------------------------------------------
# Private hosted zone
# -----------------------------------------------------------------------------
variable "private_dns_zone" {
  description = <<-EOT
    Private hosted zone for stable internal names. The RPC server certificate is
    issued for rpc.<this zone> (scripts/pki/issue-app-rpc-cert.sh), so the name
    must resolve inside the VPC or every TLS client fails hostname verification.

    The zone lives in `shared` because both clusters resolve against it; the
    `rpc` record is written by `chain`, which is the root that knows the NLB.
  EOT
  type        = string
  default     = "chain.internal"
}

variable "create_private_dns_zone" {
  description = "Create the private hosted zone. Set false if the cloud team operates a central zone for this VPC and will delegate or host the record themselves."
  type        = bool
  default     = true
}
