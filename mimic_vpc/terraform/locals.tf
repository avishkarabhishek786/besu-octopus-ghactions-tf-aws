# =============================================================================
# locals.tf — the subnet plan
# -----------------------------------------------------------------------------
# THE SUBNET PLAN IS DERIVED, NEVER HARDCODED. Every CIDR below is calculated
# from var.vpc_cidr with cidrsubnet(), so changing the /20 moves all 15 subnets
# coherently. This mirrors the no-hardcoding rule inherited from `besu-aws`.
#
# Plan for a /20 (4,096 addresses) — matches docs/spec Appendix A exactly:
#
#   role      count  size  usable each  usable total   why
#   -------   -----  ----  -----------  ------------   ------------------------
#   ledger      3    /24       251          753        Besu nodes + pods (#11)
#   app         3    /23       507        1,521        application nodes + pods
#   lb          3    /26        59          177        internal NLB / ALB (#4)
#   endpoint    3    /26        59          177        interface endpoint ENIs (#16)
#   data        3    /26        59          177        managed DBs, caches
#   -------                              ---------
#   TOTAL      15                          2,805       (2,880 of 4,096 allocated)
#                                                       1,216 held in reserve
#
# WHY THE `base` NETNUMS ARE NOT CONTIGUOUS
#   cidrsubnet() netnums are relative to the prefix length being carved, so the
#   bases below are chosen so the blocks do NOT overlap across different sizes:
#     ledger  /24 netnum 0,1,2   -> x.x.0.0  x.x.1.0  x.x.2.0     (x.x.3.0/24 reserved)
#     app     /23 netnum 2,3,4   -> x.x.4.0  x.x.6.0  x.x.8.0
#     lb      /26 netnum 40,41,42-> x.x.10.0 x.x.10.64 x.x.10.128
#     endpoint/26 netnum 44,45,46-> x.x.11.0 x.x.11.64 x.x.11.128
#     data    /26 netnum 48,49,50-> x.x.12.0 x.x.12.64 x.x.12.128
#   Everything from x.x.13.0 upward, plus x.x.3.0/24, is the reserve.
#
#   #16 REQUIRES `endpoint` and `lb` to be DISTINCT subnets — endpoint ENIs must
#   not share a subnet with the NLB nodes they front, or the same-VPC PrivateLink
#   path from the application cluster to the ledger becomes unreliable.
# =============================================================================

locals {
  subnet_plan = {
    ledger   = { newbits = 4, base = 0 }
    app      = { newbits = 3, base = 2 }
    lb       = { newbits = 6, base = 40 }
    endpoint = { newbits = 6, base = 44 }
    data     = { newbits = 6, base = 48 }
  }

  # Flatten role x AZ into a single map keyed "<role>-<az_id>", e.g.
  # "ledger-afs1-az1". A flat map lets the subnets module drive every subnet,
  # route table, association and NACL from one for_each.
  subnets = merge([
    for role, cfg in local.subnet_plan : {
      for idx, az_id in var.az_ids :
      "${role}-${az_id}" => {
        role  = role
        az_id = az_id
        cidr  = cidrsubnet(var.vpc_cidr, cfg.newbits, cfg.base + idx)
      }
    }
  ]...)

  # Subnets that carry Kubernetes load balancers need the discovery tag (#4).
  # With TWO clusters sharing one VPC the cluster-ownership tags must name both,
  # or the AWS Load Balancer Controller cannot tell which subnets it may use.
  lb_subnet_tags = {
    "kubernetes.io/role/internal-elb"                  = "1"
    "kubernetes.io/cluster/${var.ledger_cluster_name}" = "shared"
    "kubernetes.io/cluster/${var.app_cluster_name}"    = "shared"
  }
}
