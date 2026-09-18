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
