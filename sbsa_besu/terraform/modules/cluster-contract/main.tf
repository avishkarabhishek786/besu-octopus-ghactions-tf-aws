# =============================================================================
# modules/cluster-contract — CREATES NO INFRASTRUCTURE. ASSERTS EVERYTHING.
# -----------------------------------------------------------------------------
# The EKS analogue of modules/network-contract, and it exists for the same
# reason one level up the stack: since CT-5 the CLUSTER belongs to another team
# too. Every assumption we make about it is a silent dependency, and the ones
# that break do not error — they hang, or they look like success.
#
# Each gate cites a requirement number from
# docs/NETWORK_REQUIREMENTS_CLOUD_TEAM.md §9.3, so a failure can be quoted
# straight back to the cloud team rather than described.
#
# WHY `terraform_data` AND NOT `check` BLOCKS
#   `check` emits a WARNING and lets the apply proceed. These are gates, not
#   advisories. `terraform_data` with `lifecycle` preconditions FAILS THE PLAN
#   and creates no AWS resource — only a state placeholder.
#
# WHAT THIS MODULE CANNOT DO, AND WHY IT SAYS SO
#   Terraform can only assert what the AWS API will tell this principal, at plan
#   time. Three important things fall outside that:
#     * every Kubernetes-side fact (CRDs, controllers, quotas, PSA, RBAC). The
#       API endpoint is private, so only the runner can ask —
#       scripts/preflight/verify-cluster.sh and verify-admission.sh.
#     * whether the node role can actually pull. That is a different principal
#       in a different account: verify-pull-canary.sh.
#     * whether a declared boolean is TRUE. `network_policy_enforced = true` is
#       an attestation; the deny-probe in verify-deployed.sh is the measurement.
#   A gate that is skipped appears in the `gates_skipped` output. Surface it:
#   a skipped gate that reads as a pass is how this module would become
#   decorative, which is the whole failure class it was built against.
# =============================================================================

locals {
  our_namespaces = compact([var.namespace_ledger, var.namespace_app])

  # ---------------------------------------------------------------------------
  # Version arithmetic. Terraform has no version-compare function and a STRING
  # compare is wrong in the one case that matters: "1.9" > "1.10" lexically.
  # Encode major.minor as a single integer instead.
  # ---------------------------------------------------------------------------
  _vnum = {
    for k, v in {
      live = data.aws_eks_cluster.this.version
      min  = var.cluster_version_min_tested
      max  = var.cluster_version_max_tested
      said = var.cluster_version
      } : k => (
      tonumber(split(".", v)[0]) * 1000 + tonumber(split(".", v)[1])
    )
  }

  # ---------------------------------------------------------------------------
  # #31 — IRSA trust-policy shape.
  # ---------------------------------------------------------------------------
  # flatten([doc.Statement]) handles both forms: IAM normally renders Statement
  # as a list, but a single-statement document may decode to one object, and
  # indexing [0] into that would fail the plan with a type error rather than a
  # requirement citation.
  _trust_conditions = {
    for name, r in data.aws_iam_role.irsa : name => flatten([
      for st in flatten([jsondecode(r.assume_role_policy).Statement]) : [
        for op, kv in try(st.Condition, {}) : [
          for k, v in kv : { op = op, key = lower(k), values = flatten([v]) }
        ]
      ]
    ])
  }

  _trust_sub = { for n, cs in local._trust_conditions : n => [for c in cs : c if endswith(c.key, ":sub")] }
  _trust_aud = { for n, cs in local._trust_conditions : n => [for c in cs : c if endswith(c.key, ":aud")] }

  # A :sub condition is only useful if every value it permits is scoped to one
  # of OUR namespaces. A wildcard, or another namespace, is a cross-tenant path.
  _trust_sub_unscoped = {
    for n, subs in local._trust_sub : n => flatten([
      for c in subs : [
        for v in c.values : v
        if !anytrue([for ns in local.our_namespaces : startswith(v, "system:serviceaccount:${ns}:")])
      ]
    ])
  }

  irsa_roles_missing_sub = [for n, s in local._trust_sub : n if length(s) == 0]
  irsa_roles_missing_aud = [for n, a in local._trust_aud : n if length(a) == 0]
  irsa_roles_unscoped    = [for n, v in local._trust_sub_unscoped : n if length(v) > 0]

  # ---------------------------------------------------------------------------
  # Which gates could not run. Honest reporting is a design requirement here:
  # see the module header.
  # ---------------------------------------------------------------------------
  gates_skipped = compact([
    length(var.irsa_role_names) == 0 ? "#31 IRSA trust-policy scoping — no irsa_role_names supplied" : "",
    # Not "not supplied" — NOT POSSIBLE HERE. See CG-6.
    "#38 ECR repository policies — not checkable at plan time (no aws_ecr_repository_policy DATA source exists); done by verify-pull-canary.sh --check-policy",
    length(var.cluster_node_subnet_ids) == 0 ? "node subnet placement — no cluster_node_subnet_ids supplied" : "",
  ])
}

data "aws_eks_cluster" "this" {
  name = var.cluster_name
}

data "aws_iam_role" "irsa" {
  for_each = toset(var.irsa_role_names)
  name     = each.value
}

data "aws_subnet" "nodes" {
  for_each = var.cluster_node_subnet_ids
  id       = each.value
}

data "aws_subnet" "lb" {
  for_each = var.cluster_lb_subnet_ids
  id       = each.value
}

# -----------------------------------------------------------------------------
# CG-0 — HAND-OVER COHERENCE. Variables only. No data source. Deliberately.
# -----------------------------------------------------------------------------
# WHY THIS IS A SEPARATE BLOCK, AND MUST STAY ONE
#   Terraform does not evaluate a resource's preconditions when something the
#   resource depends on failed to resolve. So a precondition that reads only
#   variables is SILENTLY SKIPPED if it shares a `terraform_data` block with one
#   that reads `data.aws_eks_cluster.this`.
#
#   That is not academic here, it is the single most likely failure: a region
#   mismatch makes the cluster lookup fail, so the operator sees
#
#       Error: reading EKS Cluster (shared-eks): couldn't find resource
#
#   instead of "you are pointing at the wrong region" — which is the actual
#   cause, and was already computable without calling AWS at all. The diagnostic
#   has to survive the failure it diagnoses.
#
#   Found by driving each gate to failure rather than by reading the code; the
#   first version of this module had both checks in one block and neither fired.
#   Keep every variables-only precondition here, and never add one that touches
#   a data source.
resource "terraform_data" "handover_coherence" {
  input = "${var.cluster_name}@${var.cluster_region}"

  lifecycle {
    precondition {
      condition     = var.deploy_region == var.cluster_region
      error_message = "REGION MISMATCH: this root deploys into '${var.deploy_region}' but the cluster hand-over describes a cluster in '${var.cluster_region}'. Cluster, subnet and security-group IDs do not travel between regions — re-request eks-handover.auto.tfvars for '${var.deploy_region}', or correct primary_region. (If you also see 'couldn't find resource' for the cluster, THIS is why: the lookup ran in the wrong region.)"
    }
    precondition {
      condition     = var.pod_identity != (var.oidc_provider_arn != "")
      error_message = "#31 VIOLATED: the hand-over declares ${var.pod_identity ? "pod_identity = true" : "pod_identity = false"} and ${var.oidc_provider_arn != "" ? "also supplies oidc_provider_arn" : "supplies no oidc_provider_arn"}. Exactly one mechanism must be named. With NEITHER, our service accounts get no credentials, the AWS SDK falls through to instance metadata, and the pod runs as the CLOUD TEAM'S NODE ROLE — which on a shared cluster may well SUCCEED with wider privilege than we asked for, in their CloudTrail rather than ours. Nothing errors."
    }
  }
}

# -----------------------------------------------------------------------------
# CG-1 — a stale hand-over, against the LIVE cluster.
# -----------------------------------------------------------------------------
# Everything here needs the data source, which is why the region and
# pod-identity checks are in CG-0 instead.
resource "terraform_data" "identity" {
  input = var.cluster_name

  lifecycle {
    precondition {
      condition     = var.cluster_endpoint == "" || var.cluster_endpoint == data.aws_eks_cluster.this.endpoint
      error_message = "STALE HAND-OVER: eks-handover declares endpoint '${var.cluster_endpoint}' but cluster '${var.cluster_name}' actually serves '${data.aws_eks_cluster.this.endpoint}'. The file describes a different cluster, or one that was rebuilt. Re-request it — do not edit the endpoint to match, because every other value in the file is suspect too."
    }
    precondition {
      condition     = local._vnum.said == local._vnum.live
      error_message = "STALE HAND-OVER: eks-handover declares Kubernetes ${var.cluster_version}, the live cluster is ${data.aws_eks_cluster.this.version}. If they upgraded without telling us, that is exactly what #29 item 3 and #36 exist to prevent — ask for the notice period before accepting the new version, and run the Besu/chart compatibility pass."
    }
  }
}

# -----------------------------------------------------------------------------
# CG-2 — the API endpoint must be private-only (#32).
# -----------------------------------------------------------------------------
# A public endpoint on a cluster hosting a payment ledger's validators is a
# finding we would have to explain, and it is not ours to fix. It is also the
# one cluster attribute whose wrongness is completely invisible from inside:
# everything works, slightly more reachably than intended.
resource "terraform_data" "endpoint_access" {
  input = var.cluster_name

  lifecycle {
    precondition {
      condition     = data.aws_eks_cluster.this.vpc_config[0].endpoint_private_access
      error_message = "#32 VIOLATED: the cluster's PRIVATE endpoint access is disabled. The administrative instance reaches the API over the private endpoint (D-34); with it off there is no path at all, and the symptom is a connection that hangs rather than one that is refused."
    }
    precondition {
      condition     = !data.aws_eks_cluster.this.vpc_config[0].endpoint_public_access
      error_message = "#32 VIOLATED: the cluster's API endpoint is PUBLIC. We asked for private-only. This is the cloud team's setting to change, and until it is changed the ledger's control plane is reachable from the internet — nothing on our side reports it, because from inside the VPC a public endpoint behaves identically to a private one."
    }
  }
}

# -----------------------------------------------------------------------------
# CG-3 — the Kubernetes version, with a CEILING (#36, D-41).
# -----------------------------------------------------------------------------
resource "terraform_data" "version" {
  input = data.aws_eks_cluster.this.version

  lifecycle {
    precondition {
      condition     = local._vnum.live >= local._vnum.min
      error_message = "#36 VIOLATED: the cluster runs Kubernetes ${data.aws_eks_cluster.this.version}, below our tested floor ${var.cluster_version_min_tested}. Our charts and Besu are validated per minor; an older cluster may lack APIs the charts use."
    }
    precondition {
      condition     = local._vnum.live <= local._vnum.max
      error_message = "#36 VIOLATED: the cluster runs Kubernetes ${data.aws_eks_cluster.this.version}, ABOVE the newest minor we have validated (${var.cluster_version_max_tested}). Run the Besu and chart compatibility pass FIRST, then raise cluster_version_max_tested. Raising it to make this plan pass is the one change that defeats this gate: the failure it prevents is a removed API version stopping a chart from reconciling on an apply weeks after their upgrade, with nothing linking the two."
    }
  }
}

# -----------------------------------------------------------------------------
# CG-4 — the OIDC provider must belong to THIS cluster (#31).
# -----------------------------------------------------------------------------
# The exclusivity check (IRSA xor Pod Identity) is in CG-0, because it needs no
# AWS call and must fire even when the cluster lookup fails.
resource "terraform_data" "pod_identity" {
  input = var.pod_identity ? "pod-identity" : "irsa"

  lifecycle {
    precondition {
      condition     = var.pod_identity || var.oidc_issuer_url == "" || trimsuffix(var.oidc_issuer_url, "/") == trimsuffix(data.aws_eks_cluster.this.identity[0].oidc[0].issuer, "/")
      error_message = "#31 VIOLATED: the hand-over's OIDC issuer '${var.oidc_issuer_url}' is not this cluster's issuer ('${data.aws_eks_cluster.this.identity[0].oidc[0].issuer}'). The IAM OIDC provider belongs to a DIFFERENT cluster, so AssumeRoleWithWebIdentity will reject every token our pods present — and worse, a trust policy built on it would silently also trust that other cluster's pods."
    }
  }
}

# -----------------------------------------------------------------------------
# CG-5 — our own IRSA trust policies must be scoped (#31).
# -----------------------------------------------------------------------------
# This gate is about OUR mistake, not theirs, and it is the sharpest consequence
# of moving onto a shared cluster. A trust policy conditioned only on the OIDC
# provider — no `:sub` — is assumable by ANY pod in ANY namespace of that
# cluster. On a cluster we owned, that was untidy. Here it is a path from
# another tenant's pod to the validator keys, and it fails OPEN: everything
# works, including for people who should not have it.
resource "terraform_data" "irsa_scoping" {
  input = length(var.irsa_role_names)

  lifecycle {
    precondition {
      condition     = length(local.irsa_roles_missing_sub) == 0
      error_message = "#31 VIOLATED: IRSA role(s) ${jsonencode(local.irsa_roles_missing_sub)} have NO `:sub` condition in their trust policy. On this SHARED cluster that means any pod in any namespace — including another tenant's — can assume them. Add a StringEquals condition on `<issuer>:sub` = `system:serviceaccount:${var.namespace_ledger}:<sa>`."
    }
    precondition {
      condition     = length(local.irsa_roles_missing_aud) == 0
      error_message = "#31 VIOLATED: IRSA role(s) ${jsonencode(local.irsa_roles_missing_aud)} have NO `:aud` condition. Add StringEquals on `<issuer>:aud` = `sts.amazonaws.com`, so a token minted for another audience cannot be replayed against this role."
    }
    precondition {
      condition     = length(local.irsa_roles_unscoped) == 0
      error_message = "#31 VIOLATED: IRSA role(s) ${jsonencode(local.irsa_roles_unscoped)} have a `:sub` condition that permits service accounts OUTSIDE our namespaces (${jsonencode(local.our_namespaces)}). A wildcard here is the same exposure as no condition at all."
    }
  }
}

# -----------------------------------------------------------------------------
# CG-6 — the registry must grant pull to THEIR node role (#38).
# -----------------------------------------------------------------------------
# §12.13.2 assigned this gate to plan time. It cannot go there, and finding that
# out is worth recording rather than hiding:
#
#   THERE IS NO `aws_ecr_repository_policy` DATA SOURCE. The AWS provider offers
#   it only as a managed resource, so a plan cannot READ an existing repository
#   policy at all. Adding one as a resource would mean this module starts
#   OWNING the policies of a central shared-services registry — the opposite of
#   "creates no infrastructure", and a plan that would fight whoever does own
#   them.
#
# So the policy assertion moved to where one API call answers it:
# `scripts/preflight/verify-pull-canary.sh --check-policy`, which reports the
# cause before the canary reports the verdict. That layering is better anyway:
# the policy read names WHY, the canary proves WHETHER, and only the canary uses
# the right principal (D-38).
#
# What stays here is the half that is a decision rather than a measurement.
resource "terraform_data" "registry_pull" {
  input = var.node_role_arn

  lifecycle {
    precondition {
      condition     = var.node_role_ecr_auth_confirmed
      error_message = "#38, second half: node_role_ecr_auth_confirmed is false. The node role needs `ecr:GetAuthorizationToken` in its own IDENTITY policy — no repository policy can grant it, and one hardened to their own registry account will refuse ours. Confirm which policy the role carries (the managed AmazonEC2ContainerRegistryReadOnly includes it), then set this true. NOTE: this is an ATTESTATION, not a measurement. Setting it true does not make it so; the proof is scripts/preflight/verify-pull-canary.sh, which pulls as that role."
    }
    precondition {
      condition     = var.node_role_arn != ""
      error_message = "#38: node_role_arn is empty. It is the principal that actually pulls our images (kubelet's ECR credential provider), so without it our repository policies cannot be written and verify-pull-canary.sh --check-policy has nothing to look for. It comes from the cloud team alongside the node security group ID (#33)."
    }
  }
}

# -----------------------------------------------------------------------------
# CG-7 — the add-on with no fallback, and the storage with no fallback (#30).
# -----------------------------------------------------------------------------
resource "terraform_data" "addons" {
  input = var.cluster_provides_lbc

  lifecycle {
    precondition {
      condition     = var.cluster_provides_lbc
      error_message = "#30 VIOLATED: the cluster does not provide the AWS Load Balancer Controller. This is the ONE add-on with no workaround — our SWIFT and application RPC endpoints are exposed by binding pods into NLB target groups we own, via the TargetGroupBinding CRD. Without it there is no RPC endpoint at all. Everything else in #30 degrades the operational posture; this stops the platform."
    }
    precondition {
      condition     = var.storage_class_name != ""
      error_message = "#30 VIOLATED: no StorageClass was named. The chain needs persistent volumes and there is no fallback. Ask for a gp3, encrypted class with volumeBindingMode: WaitForFirstConsumer and allowVolumeExpansion: true — the binding mode matters because Immediate pins the volume to an arbitrary AZ before the pod is scheduled, which can leave a validator permanently Pending with its data in the wrong zone."
    }
  }
}

# -----------------------------------------------------------------------------
# CG-8 — Pod Security versus the F32 init container (#27, D-33).
# -----------------------------------------------------------------------------
resource "terraform_data" "pod_security" {
  input = var.psa_level

  lifecycle {
    precondition {
      condition     = !(var.psa_level == "restricted" && var.validator_init_runs_as_root)
      error_message = "#27 VIOLATED: psa_level is 'restricted' and the F32 ownership-fix init container still runs as uid 0, which `restricted` refuses AT ADMISSION. Every validator pod is refused before it starts, and the symptom is a StatefulSet with zero replicas and an event nobody is watching. Either ask for 'baseline' on our namespaces, or rework the init container non-root and set validator_init_runs_as_root = false. NOTE: a 'baseline' answer here is not conclusive — PSA can also be enforced cluster-wide via AdmissionConfiguration, invisible in namespace labels (question K). verify-admission.sh is what settles it."
    }
  }
}

# -----------------------------------------------------------------------------
# CG-9 — THE ISOLATION FLOOR (#28, #35; D-26, D-9).
# -----------------------------------------------------------------------------
# The most important gate in this module, and the only one that is purely about
# a combination rather than a value.
#
# Two things isolate the validators on a cluster we share. The dedicated tainted
# node group (#28) keeps other tenants' pods off the validators' kernel. The
# CNI's NetworkPolicy enforcement (#35) keeps their traffic off the validators'
# RPC. D-26 says plainly that if #28 is refused, NetworkPolicy default-deny is
# the COMPENSATING control — which only works if something enforces it.
#
# With both absent there is no boundary at all: a payment ledger's validators
# sharing a kernel with arbitrary tenants, and policies the API accepts and
# nothing applies. No downstream gate catches that, because each half looks like
# an accepted trade-off on its own.
resource "terraform_data" "isolation_floor" {
  input = "${var.node_group_dedicated}/${var.network_policy_enforced}"

  lifecycle {
    precondition {
      condition     = var.node_group_dedicated || var.network_policy_enforced
      error_message = "ISOLATION FLOOR VIOLATED (#28 and #35 both absent): no dedicated node group AND no NetworkPolicy enforcement. Either alone is a recorded trade-off — D-26 makes NetworkPolicy default-deny the compensating control when #28 is refused. BOTH absent means the validators of a payment ledger share a kernel with arbitrary tenants while our default-deny policies are accepted by the API server and enforced by nothing. This is not a tfvars problem; go back to the cloud team with #28 or #35."
    }
    precondition {
      condition     = !var.node_group_dedicated || (var.node_taint != "" && var.node_label != "")
      error_message = "#28: node_group_dedicated is true but node_taint ('${var.node_taint}') or node_label ('${var.node_label}') is empty. Without both, our pods carry no toleration and no selector — so they schedule onto the SHARED nodes anyway, and the dedicated group sits empty. The dedication would be real and we would not be using it."
    }
  }
}

# -----------------------------------------------------------------------------
# CG-10 — the things without which nothing can be deployed (#32, #27).
# -----------------------------------------------------------------------------
resource "terraform_data" "access" {
  input = var.namespace_ledger

  lifecycle {
    precondition {
      condition     = var.runner_access_entry_created
      error_message = "#32: runner_access_entry_created is false. The administrative instance needs an EKS access entry for its IAM role, scoped to our namespaces — it applies the Helm releases and runs the one-validator-at-a-time upgrade script. It is the cloud team's to create (D-34), so this is a declared fact rather than something we can build. Nothing deploys until it exists."
    }
    precondition {
      condition     = var.namespace_ledger != ""
      error_message = "#27: no ledger namespace was named. We never create it (D-23) — it is allotted."
    }
    precondition {
      condition     = !contains(["kube-system", "kube-public", "kube-node-lease", "default"], var.namespace_ledger)
      error_message = "#27: namespace_ledger is '${var.namespace_ledger}'. That is a cluster-owned namespace, not one allotted to a tenant. Deploying there would put the ledger outside its own quota and RBAC boundary, and a scoped access entry (#32) would not reach it anyway."
    }
  }
}

# -----------------------------------------------------------------------------
# CG-11 — our placement is inside this cluster's VPC and region.
# -----------------------------------------------------------------------------
# Cheap, and it catches a hand-over assembled from two different sources — which
# is the normal way a hand-over goes wrong once three teams touch it.
resource "terraform_data" "placement" {
  input = length(var.cluster_node_subnet_ids)

  lifecycle {
    precondition {
      condition = alltrue([
        for k, s in data.aws_subnet.nodes : s.vpc_id == data.aws_eks_cluster.this.vpc_config[0].vpc_id
      ])
      error_message = "Hand-over mismatch: one or more cluster_node_subnet_ids are not in cluster '${var.cluster_name}'s VPC (${data.aws_eks_cluster.this.vpc_config[0].vpc_id}). The file has been assembled from two different sources."
    }
    precondition {
      condition = alltrue([
        for k, s in data.aws_subnet.lb : s.vpc_id == data.aws_eks_cluster.this.vpc_config[0].vpc_id
      ])
      error_message = "Hand-over mismatch: one or more cluster_lb_subnet_ids are not in cluster '${var.cluster_name}'s VPC (${data.aws_eks_cluster.this.vpc_config[0].vpc_id})."
    }
    precondition {
      condition = alltrue([
        for k, s in data.aws_subnet.nodes : s.availability_zone_id == k
      ])
      error_message = "Hand-over mismatch: cluster_node_subnet_ids is keyed by AZ ID, but at least one subnet is not in the AZ its key names. Subnet maps are keyed by AZ ID and never by index or AZ name, precisely so a reordered hand-over cannot silently move the validators into two zones instead of three."
    }
  }
}
