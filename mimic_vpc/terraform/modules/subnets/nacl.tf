# =============================================================================
# nacl.tf — the cloud team's subnet security rules (CT-1a, D-29, D-32)
# -----------------------------------------------------------------------------
# REPLACES the permissive allow-all baseline that shipped until 2026-10-09.
#
# WHY IT CHANGED
#   The old baseline was allow-all "because Phase 2/3 owns the rules". Under
#   CT-1a the CLOUD TEAM owns the rules and ours is to conform — so an allow-all
#   mimic hides exactly the failure class they described, and the platform's
#   verify-subnet-rules.sh would have been written against a fixture that could
#   never reject anything. A check that cannot fail is worse than no check,
#   because it is trusted (B12, CICD §11.3).
#
#   Deny-by-default, permitting only the flows in requirement #34 (F-1..F-10) —
#   the canonical table in sbsa_besu/docs/CLOUD_TEAM_SHARED_CLUSTER_REQUIREMENTS.md.
#
# -----------------------------------------------------------------------------
# WHAT WE LEARNED BUILDING THIS, AND IT MATTERS FOR THE DESIGN
# -----------------------------------------------------------------------------
# A NACL is STATELESS, so every permitted flow needs a matching return rule over
# the ephemeral port range — conventionally 1024-65535.
#
#   EVERY PORT THIS PLATFORM LISTENS ON IS INSIDE THAT RANGE.
#   Besu P2P 30303, JSON-RPC 8545, WS 8546, metrics 9545, Postgres 5432.
#
# So a NACL that permits ephemeral return traffic from a source CIDR has, by
# construction, also permitted INBOUND CONNECTIONS to every one of those
# services from that same CIDR. The "stateless L3 boundary" the design claimed
# for #13 is therefore much weaker than it reads for our ports specifically: it
# can separate SUBNETS, but it cannot protect a service on a high port from
# anything already allowed to reply to us.
#
# Two consequences, both recorded in the design notes:
#   * return rules are scoped to the NARROWEST source CIDR that works — the
#     endpoint subnets, the data subnets, the LB subnets — never the VPC CIDR,
#     because "the VPC" would hand every pod inbound reach to every validator's
#     RPC via the return rule alone;
#   * the real tenant boundary is NetworkPolicy (#35) and security groups (#6),
#     not this. Withdrawing #13 as an ask cost us less than it appeared to.
#
# AWS limits a NACL to 20 rules per direction by default, which is why these are
# consolidated by source group rather than written one per flow.
# =============================================================================

locals {
  # Re-declared here with the NACLs that use it; it was declared beside the old
  # permissive baseline, which nacl.tf replaced.
  ledger_subnet_keys = [for k, v in var.subnets : k if v.role == "ledger"]

  # Supernets per role, so a rule names "the app subnets" rather than three
  # CIDRs. Derived, never restated: a subnet plan change must not need a rule
  # edit (CD-12 in spirit).
  role_cidrs = {
    for role in distinct([for k, v in var.subnets : v.role]) :
    role => [for k, v in var.subnets : v.cidr if v.role == role]
  }

  # F-6 — S3's regional ranges. A NACL CANNOT reference a prefix list, which is
  # the trap #34 F-6 names explicitly. The default below is 0.0.0.0/0 and that
  # is NOT a shortcut we are hiding: the real cloud team faces the same
  # limitation and must either widen this rule or enumerate the ranges from
  # `aws ec2 describe-managed-prefix-lists`. Set s3_cidrs to exercise the
  # enumerated form.
  s3_cidrs = length(var.s3_cidrs) > 0 ? var.s3_cidrs : ["0.0.0.0/0"]

  eph = { from = 1024, to = 65535 }

  # ---------------------------------------------------------------------------
  # THE RULE BUDGET — why these sources are not all per-subnet.
  # ---------------------------------------------------------------------------
  # AWS allows 20 rules per NACL PER DIRECTION by default (raisable to 40, with
  # a documented network-performance caveat). Expressing #34's flow table with a
  # per-AZ CIDR for every counterparty needs 26 ingress and 30 egress rules on
  # the workload subnets — it DOES NOT FIT, and the failure would otherwise be an
  # AWS API error mid-apply naming a rule number.
  #
  # That is a finding about the requirement, not about this fixture: it predicts
  # what the real cloud team will say. Either they answer question C with
  # "security groups", or they need a quota increase, or they summarise. #34 now
  # says so.
  #
  # "summarised" (default) keeps a NARROW per-subnet source on the SERVICE ports,
  # where narrowing genuinely restricts who may open a connection, and uses the
  # VPC CIDR for the ephemeral RETURN ranges, where — as the header explains —
  # narrowing is largely illusory anyway because every port we listen on is
  # inside 1024-65535. "narrow" uses per-subnet sources everywhere and requires
  # the quota increase; keep it available, because it is what a security review
  # asks for and it is the right answer once the quota is raised.
  wide = var.nacl_source_mode == "narrow"

  # Under CT-5 our pods land in the APPLICATION subnets. The ledger-subnet peer
  # rules exist only if #28 is granted, and carrying them unconditionally costs
  # 12 rules on the subnets that are already tightest.
  ledger_peer_cidrs = var.ledger_subnets_in_use ? local.role_cidrs["ledger"] : []

  # ---------------------------------------------------------------------------
  # THE CLUSTER'S OWN FLOWS (C-1..C-4) — added 2026-10-10 for B27.
  # ---------------------------------------------------------------------------
  # #34's F-1..F-10 are OUR flows. The first mimic_eks apply (2026-10-09) proved
  # that a NACL carrying only those cannot host a cluster across three AZs: EKS
  # put control-plane ENIs in two of the three node subnets, the node in the
  # third reached them only across a NACL with no ingress 443, and it never
  # joined. Traffic inside one subnet is not NACL-evaluated, which is the only
  # reason the other two nodes worked. The same table is in #34 for the cloud
  # team ("The cluster's own flows must keep working too"):
  #
  #   C-1  nodes -> cluster API (control-plane ENIs)   tcp 443, across subnets
  #   C-2  pods -> CoreDNS                             udp+tcp 53, across subnets
  #   C-3  control plane -> kubelet 10250 / webhooks   tcp high ports
  #   C-4  pod <-> pod, node <-> node                  as the CNI requires
  #
  # mimic_eks puts its control-plane ENIs in the NODE subnets (cluster
  # subnet_ids = node subnets): the app subnets, or the ledger subnets when #28
  # is granted (strict). So the cluster's subnets are the workload subnets, and
  # ledger_subnets_in_use must be true whenever a strict cluster is built here.
  #
  # F-7 (In-VPC EC2 Runner -> cluster API) was broken by the same omission and
  # nobody saw it (B32): the runner's 443 rule was EGRESS only, the control-plane
  # ENIs' subnets had no ingress 443, and verify-subnet-rules.sh had no F-7
  # section. The runner sits in a ledger subnet, so the API's ingress sources
  # include the ledger subnets even when #28 is not granted.
  #
  # WHERE EACH CLUSTER FLOW RIDES, PER MODE — read before using nacl_break_flow:
  #   summarised  C-1, C-2 get their own VPC-CIDR rules on the low ports (443,
  #               53), which no existing rule covered. C-3/C-4 and every TCP
  #               return ride the VPC-CIDR ephemeral rules F-5 (in) and F-4
  #               (out), merged with F-9's and F-3's identical rules (see
  #               nacl_flows_merged) — so breaking "C-3" removes those rules and
  #               F-5/F-9/F-4/F-3 with them. That is the truth about one
  #               shared rule, not a side effect to work around. C-2's egress
  #               rides F-10's DNS rules, labelled likewise.
  #   narrow      per-subnet rules for every cluster flow, including an explicit
  #               ephemeral rule between cluster subnets. Needs the 40 quota.
  cluster_cidrs    = distinct(concat(local.role_cidrs["app"], local.ledger_peer_cidrs))
  api_client_cidrs = distinct(concat(local.cluster_cidrs, local.role_cidrs["ledger"]))

  # The labels of the summarised-mode rules that also carry a cluster flow.
  c3_in_label  = local.wide ? "" : " + C-3 control plane -> kubelet/webhooks, C-4 pod<->pod, and the tcp returns of the API and DNS flows"
  c3_out_label = local.wide ? "" : " + C-3 control plane -> kubelet/webhooks, C-4 pod<->pod, and the tcp returns of the API and DNS flows"

  # ---------------------------------------------------------------------------
  # The rule set, per role and direction. Each rule CITES ITS FLOW, so a
  # verify-subnet-rules.sh failure and a mimic rule can be matched by eye.
  # ---------------------------------------------------------------------------
  # Rule numbers leave gaps on purpose: inserting a flow later must not renumber
  # existing rules, because a NACL rule number is its identity and Terraform
  # would otherwise replace unrelated rules.
  # ---------------------------------------------------------------------------
  nacl_flows = {
    # --- the subnets our pods run in (app; and ledger when #28 is granted) ---
    workload = {
      ingress = concat(
        [for c in local.role_cidrs["app"] : { n = 100, proto = "tcp", from = 30303, to = 30303, cidr = c, flow = "F-1 peer TCP" }],
        [for c in local.role_cidrs["app"] : { n = 105, proto = "udp", from = 30303, to = 30303, cidr = c, flow = "F-1 peer UDP (discovery)" }],
        [for c in local.ledger_peer_cidrs : { n = 110, proto = "tcp", from = 30303, to = 30303, cidr = c, flow = "F-1 peer TCP (ledger subnets, #28)" }],
        [for c in local.ledger_peer_cidrs : { n = 115, proto = "udp", from = 30303, to = 30303, cidr = c, flow = "F-1 peer UDP (ledger subnets, #28)" }],
        [for c in local.role_cidrs["lb"] : { n = 120, proto = "tcp", from = 8545, to = 8546, cidr = c, flow = "F-2 RPC + health checks from the NLBs" }],
        [for c in(local.wide ? local.role_cidrs["app"] : [var.vpc_cidr]) : { n = 130, proto = "tcp", from = 9545, to = 9545, cidr = c, flow = "F-4 metrics scrape" }],
        [for c in(local.wide ? local.role_cidrs["endpoint"] : [var.vpc_cidr]) : { n = 140, proto = "tcp", from = local.eph.from, to = local.eph.to, cidr = c, flow = "F-5 return from the interface endpoints${local.c3_in_label}" }],
        [for c in local.s3_cidrs : { n = 150, proto = "tcp", from = local.eph.from, to = local.eph.to, cidr = c, flow = "F-6 return from S3 (image layers, state, bundle)" }],
        [for c in(local.wide ? local.role_cidrs["data"] : [var.vpc_cidr]) : { n = 160, proto = "tcp", from = local.eph.from, to = local.eph.to, cidr = c, flow = "F-9 return from the explorer database" }],
        [{ n = 170, proto = "udp", from = local.eph.from, to = local.eph.to, cidr = var.vpc_cidr, flow = "F-10 DNS replies from the VPC resolver + C-2 replies from CoreDNS" }],
        # --- the cluster's own flows (B27) and F-7's missing half (B32) -----
        # Appended, never inserted: a rule's for_each key is its list index, so
        # an insertion would replace every rule after it. Bands are 10 apart
        # because these fan out over up to 6 CIDRs in narrow mode.
        [for c in(local.wide ? local.api_client_cidrs : [var.vpc_cidr]) : { n = 200, proto = "tcp", from = 443, to = 443, cidr = c, flow = "C-1 nodes -> cluster API (control-plane ENIs) + F-7 In-VPC EC2 Runner -> cluster API" }],
        [for c in(local.wide ? local.cluster_cidrs : [var.vpc_cidr]) : { n = 210, proto = "udp", from = 53, to = 53, cidr = c, flow = "C-2 pods -> CoreDNS (udp)" }],
        [for c in(local.wide ? local.cluster_cidrs : [var.vpc_cidr]) : { n = 220, proto = "tcp", from = 53, to = 53, cidr = c, flow = "C-2 pods -> CoreDNS (tcp)" }],
        [for c in(local.wide ? local.api_client_cidrs : []) : { n = 230, proto = "tcp", from = local.eph.from, to = local.eph.to, cidr = c, flow = "C-3 control plane -> kubelet/webhooks, C-4 pod<->pod, and the tcp returns of the API and DNS flows" }],
      )
      egress = concat(
        [for c in local.role_cidrs["app"] : { n = 100, proto = "tcp", from = 30303, to = 30303, cidr = c, flow = "F-1 peer TCP" }],
        [for c in local.role_cidrs["app"] : { n = 105, proto = "udp", from = 30303, to = 30303, cidr = c, flow = "F-1 peer UDP (discovery)" }],
        [for c in local.ledger_peer_cidrs : { n = 110, proto = "tcp", from = 30303, to = 30303, cidr = c, flow = "F-1 peer TCP (ledger subnets, #28)" }],
        [for c in local.ledger_peer_cidrs : { n = 115, proto = "udp", from = 30303, to = 30303, cidr = c, flow = "F-1 peer UDP (ledger subnets, #28)" }],
        [for c in(local.wide ? local.role_cidrs["lb"] : [var.vpc_cidr]) : { n = 120, proto = "tcp", from = local.eph.from, to = local.eph.to, cidr = c, flow = "F-3 return to the NLBs (ONLY needed because NACLs are stateless)" }],
        [for c in(local.wide ? local.role_cidrs["app"] : [var.vpc_cidr]) : { n = 130, proto = "tcp", from = local.eph.from, to = local.eph.to, cidr = c, flow = "F-4 metrics reply${local.c3_out_label}" }],
        [for c in local.role_cidrs["endpoint"] : { n = 140, proto = "tcp", from = 443, to = 443, cidr = c, flow = "F-5 AWS APIs via interface endpoints" }],
        [for c in local.s3_cidrs : { n = 150, proto = "tcp", from = 443, to = 443, cidr = c, flow = "F-6 S3 gateway" }],
        [for c in local.role_cidrs["data"] : { n = 160, proto = "tcp", from = 5432, to = 5432, cidr = c, flow = "F-9 explorer database" }],
        [{ n = 170, proto = "udp", from = 53, to = 53, cidr = var.vpc_cidr, flow = "F-10 DNS + C-2 pods -> CoreDNS" }],
        [{ n = 175, proto = "tcp", from = 53, to = 53, cidr = var.vpc_cidr, flow = "F-10 DNS over TCP + C-2 pods -> CoreDNS" }],
        # F-7 and F-8 ride the workload subnets because that is where the
        # In-VPC EC2 Runner lives (CT-1a leaves its subnet to them).
        # The target is every subnet that can hold a control-plane ENI, which is
        # the cluster's subnets — the ledger ones too when #28 is granted. Up to
        # 6 CIDRs, so 180..185; F-8's band at 190 is clear.
        [for c in(local.wide ? local.cluster_cidrs : [var.vpc_cidr]) : { n = 180, proto = "tcp", from = 443, to = 443, cidr = c, flow = "F-7 In-VPC EC2 Runner -> cluster API (control-plane ENIs) + C-1 nodes -> cluster API" }],
        var.egress_proxy_cidr == "" ? [] : [{ n = 190, proto = "tcp", from = var.egress_proxy_port, to = var.egress_proxy_port, cidr = var.egress_proxy_cidr, flow = "F-8 In-VPC EC2 Runner -> egress proxy (R-10)" }],
        # --- the cluster's own flows (B27) — appended, as on ingress ---------
        # CoreDNS answers from 53 to the client's ephemeral port. No existing
        # egress rule carried UDP above 1024 at all.
        [for c in(local.wide ? local.cluster_cidrs : [var.vpc_cidr]) : { n = 200, proto = "udp", from = local.eph.from, to = local.eph.to, cidr = c, flow = "C-2 CoreDNS replies (udp)" }],
        [for c in(local.wide ? local.api_client_cidrs : []) : { n = 210, proto = "tcp", from = local.eph.from, to = local.eph.to, cidr = c, flow = "C-3 control plane -> kubelet/webhooks, C-4 pod<->pod, and the tcp returns of the API and DNS flows" }],
      )
    }

    # --- the load-balancer subnets -------------------------------------------
    lb = {
      ingress = concat(
        [{ n = 100, proto = "tcp", from = 8545, to = 8546, cidr = var.sipn_cidr != "" ? var.sipn_cidr : var.vpc_cidr, flow = "clients -> the NLBs (SWIFT over SIPN in production)" }],
        [for c in local.role_cidrs["app"] : { n = 110, proto = "tcp", from = local.eph.from, to = local.eph.to, cidr = c, flow = "F-3 return from the pods" }],
      )
      egress = concat(
        [for c in local.role_cidrs["app"] : { n = 100, proto = "tcp", from = 8545, to = 8546, cidr = c, flow = "F-2 to the pod targets + health checks" }],
        [for c in local.role_cidrs["ledger"] : { n = 110, proto = "tcp", from = 8545, to = 8546, cidr = c, flow = "F-2 to pod targets in the ledger subnets (#28)" }],
        [{ n = 120, proto = "tcp", from = local.eph.from, to = local.eph.to, cidr = var.sipn_cidr != "" ? var.sipn_cidr : var.vpc_cidr, flow = "replies to clients" }],
      )
    }

    # --- the interface-endpoint subnets --------------------------------------
    endpoint = {
      ingress = [{ n = 100, proto = "tcp", from = 443, to = 443, cidr = var.vpc_cidr, flow = "F-5 AWS API calls from anywhere in the VPC" }]
      egress  = [{ n = 100, proto = "tcp", from = local.eph.from, to = local.eph.to, cidr = var.vpc_cidr, flow = "F-5 return" }]
    }

    # --- the data subnets (#37) ----------------------------------------------
    data = {
      ingress = [for c in local.role_cidrs["app"] : { n = 100, proto = "tcp", from = 5432, to = 5432, cidr = c, flow = "F-9 explorer database" }]
      egress  = [for c in local.role_cidrs["app"] : { n = 100, proto = "tcp", from = local.eph.from, to = local.eph.to, cidr = c, flow = "F-9 return" }]
    }
  }

  # Which rule set each role uses. ledger and app share one: under CT-5 our pods
  # land in app, and in ledger only if #28 is granted — the flows are identical.
  role_ruleset = {
    ledger   = "workload"
    app      = "workload"
    lb       = "lb"
    endpoint = "endpoint"
    data     = "data"
  }

  # ---------------------------------------------------------------------------
  # MERGE IDENTICAL RULES — one AWS rule per (protocol, port range, CIDR).
  # ---------------------------------------------------------------------------
  # In summarised mode several flows reduce to the SAME rule: F-3's and F-4's
  # replies are both tcp/1024-65535 to the VPC CIDR, and so are the F-5 and F-9
  # returns inbound. Until 2026-10-10 each was authored as its own AWS rule,
  # which (1) spent a rule per direction for nothing, on NACLs the B27 cluster
  # flows filled to exactly 20; and (2) made nacl_break_flow lie — breaking one
  # flow left its twin carrying the traffic, so the checker passed with the
  # "broken" flow still working (seen offline: nacl_break_flow = "C-3", 0 FAIL).
  # Merged, the rule's label names every flow it carries, so breaking any of
  # them removes the rule — which is what would happen on the real subnet.
  # The first occurrence keeps its band, so the rule's number does not move.
  _sig = { for rs, dirs in local.nacl_flows : rs => { for dir, rules in dirs : dir => [for r in rules : "${r.proto}|${r.from}|${r.to}|${r.cidr}"] } }
  nacl_flows_merged = {
    for rs, dirs in local.nacl_flows : rs => {
      for dir, rules in dirs : dir => [
        for sig in distinct(local._sig[rs][dir]) : merge(
          [for i, r in rules : r if local._sig[rs][dir][i] == sig][0],
          { flow = join(" + ", distinct([for i, r in rules : r.flow if local._sig[rs][dir][i] == sig])) }
        )
      ]
    }
  }

  # ---------------------------------------------------------------------------
  # Flatten (subnet, direction, rule) and allocate a unique rule number inside
  # each (subnet, direction). The authored `n` is a BAND, not the final number:
  # a flow fanning out over three AZ CIDRs needs three distinct numbers, and
  # AWS requires them unique per NACL per direction.
  # ---------------------------------------------------------------------------
  nacl_rule_list = flatten([
    for sk, sv in var.subnets : [
      for dir in ["ingress", "egress"] : [
        for i, r in local.nacl_flows_merged[local.role_ruleset[sv.role]][dir] : {
          key    = "${sk}-${dir}-${i}"
          subnet = sk
          egress = dir == "egress"
          # The authored `n` is a BAND; the offset is this rule's position among
          # those sharing it. Bands below 200 are 5 apart and fan out over at
          # most 3 AZ CIDRs (F-7's 180 over up to 6, clear of F-8's 190); the
          # cluster-flow bands from 200 are 10 apart for up to 6. So 100/105
          # become 100,101,102 / 105,106,107 and never collide. Gaps are deliberate: a NACL rule number IS the rule's
          # identity, so inserting a flow must not renumber its neighbours.
          rule_num = r.n + length([
            for j, x in local.nacl_flows_merged[local.role_ruleset[sv.role]][dir] : j
            if x.n == r.n && j < i
          ])
          proto = r.proto
          from  = r.from
          to    = r.to
          cidr  = r.cidr
          flow  = r.flow
        }
      ]
    ]
  ])

  nacl_rules = { for r in local.nacl_rule_list : r.key => r }

  # ---------------------------------------------------------------------------
  # THE EFFECTIVE SET — one source of truth for "what is actually on the subnet".
  # ---------------------------------------------------------------------------
  # The break filter used to live only in aws_network_acl_rule.flow's `for_each`,
  # while `nacl_rules_authored` iterated the UNFILTERED map. So the output
  # claimed to describe the live rules and did not: with nacl_break_flow set, it
  # still listed every rule, including the ones deliberately removed.
  #
  # That is the same defect this whole programme keeps finding — a statement
  # that cannot disagree with reality because it is not derived from it. Both the
  # resource and the output now read THIS.
  nacl_rules_effective = {
    for k, r in local.nacl_rules : k => r
    if var.nacl_break_flow == "" || !strcontains(r.flow, var.nacl_break_flow)
  }
}

# -----------------------------------------------------------------------------
# GATE — refuse to author a NACL that AWS would reject.
# -----------------------------------------------------------------------------
# Without this, exceeding the per-direction rule quota surfaces as an AWS API
# error partway through the apply, naming a rule number and nothing else, with
# some NACLs already written and the subnets they guard in an undefined state.
# The arithmetic is known at plan time, so the failure belongs at plan time —
# the same reasoning as every gate in the platform's two contract modules.
locals {
  # Counts the EFFECTIVE set: a break knob that removes rules must not leave the
  # budget gate complaining about rules that will not be created.
  _rule_counts = {
    for pair in distinct([for k, r in local.nacl_rules_effective : "${r.subnet}/${r.egress ? "egress" : "ingress"}"]) :
    pair => length([
      for k, r in local.nacl_rules_effective : r
      if "${r.subnet}/${r.egress ? "egress" : "ingress"}" == pair
    ])
  }
  _over_budget = { for k, v in local._rule_counts : k => v if v > var.nacl_rule_limit }
}

resource "terraform_data" "nacl_budget" {
  count = var.nacl_mode == "flows" ? 1 : 0
  input = length(local.nacl_rules_effective)

  lifecycle {
    precondition {
      condition     = length(local._over_budget) == 0
      error_message = "NACL RULE BUDGET EXCEEDED: ${jsonencode(local._over_budget)} against a limit of ${var.nacl_rule_limit} rules per NACL per direction. AWS allows 20 by default and 40 after a quota increase (Service Quotas: 'Rules per network ACL'), and raising it carries a documented network-performance caveat. Options, in the order a real cloud team would consider them: (1) nacl_source_mode = \"summarised\" (the default) which narrows only the service ports; (2) ledger_subnets_in_use = false if #28 was not granted, which frees 12 rules; (3) raise the quota and set nacl_rule_limit = 40; (4) answer question C with security groups instead, which have no equivalent limit. THIS IS ALSO A FINDING ABOUT REQUIREMENT #34: the flow table does not fit in a default NACL, and the cloud team needs to know before they promise it."
    }
  }
}

resource "aws_network_acl" "role" {
  for_each = var.nacl_mode == "none" ? {} : var.subnets

  vpc_id     = var.vpc_id
  subnet_ids = [aws_subnet.this[each.key].id]

  tags = merge(var.tags, {
    Name      = "${var.name_prefix}-nacl-${each.key}"
    Component = "network"
    Role      = each.value.role
    NaclMode  = var.nacl_mode
  })
}

# -----------------------------------------------------------------------------
# PERMISSIVE MODE — kept, not deleted, and not the default.
# -----------------------------------------------------------------------------
# An aws_network_acl with NO rules DENIES ALL TRAFFIC, so a NACL shipped without
# rules black-holes its subnet on creation. That is why the original baseline
# existed. It is retained as `nacl_mode = "permissive"` for one legitimate use:
# bisecting a connectivity problem to decide whether the NACLs are the cause.
# Using it for anything else returns the fixture to a state where
# verify-subnet-rules.sh cannot fail.
resource "aws_network_acl_rule" "permissive" {
  for_each = var.nacl_mode == "permissive" ? {
    for pair in setproduct(keys(var.subnets), ["ingress", "egress"]) :
    "${pair[0]}-${pair[1]}" => { subnet = pair[0], egress = pair[1] == "egress" }
  } : {}

  network_acl_id = aws_network_acl.role[each.value.subnet].id
  rule_number    = 100
  egress         = each.value.egress
  protocol       = "-1"
  rule_action    = "allow"
  cidr_block     = "0.0.0.0/0"
}

# -----------------------------------------------------------------------------
# FLOW MODE (default) — deny by default; only #34's F-1..F-10 and C-1..C-4.
# -----------------------------------------------------------------------------
# `nacl_break_flow` drops every rule whose flow label contains the given string,
# which is how verify-subnet-rules.sh is proven to detect a MISSING rule rather
# than merely to parse a present one. Examples that each produce a distinct,
# realistic failure:
#     nacl_break_flow = "F-1 peer UDP"  -> discovery dies, static peers still
#                                          connect, and the chain looks fine
#     nacl_break_flow = "F-6"           -> image pulls stall mid-layer
#     nacl_break_flow = "F-5"           -> every AWS SDK call hangs to timeout
resource "aws_network_acl_rule" "flow" {
  for_each = var.nacl_mode == "flows" ? local.nacl_rules_effective : {}

  network_acl_id = aws_network_acl.role[each.value.subnet].id
  rule_number    = each.value.rule_num
  egress         = each.value.egress
  protocol       = each.value.proto
  rule_action    = "allow"
  cidr_block     = each.value.cidr
  from_port      = each.value.from
  to_port        = each.value.to

  # So the budget gate cannot be skipped by Terraform choosing to create rules
  # first. A gate that the graph is free to run last is not a gate.
  depends_on = [terraform_data.nacl_budget]
}
