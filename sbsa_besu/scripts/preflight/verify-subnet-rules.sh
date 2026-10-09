#!/usr/bin/env bash
# =============================================================================
# verify-subnet-rules.sh — do the cloud team's subnet rules permit our flows?
# -----------------------------------------------------------------------------
# READ-ONLY. Two describe calls and some arithmetic. Free, a few seconds.
# Requirement #34 (D-29). Run BEFORE anything billable exists.
#
# WHY IT EXISTS
#   CT-1a: the cloud team has role-separated subnets with security rules THEY
#   define. Our validators are spread across three AZs, so EVERY
#   validator-to-validator connection crosses a subnet boundary and meets those
#   rules — and in this VPC a blocked flow does not error. It hangs, or it
#   reports a peer count of zero, or an image pull stalls mid-layer. None of
#   those name a rule.
#
#   This converts all of it into "#34 F-1 BLOCKED: NACL acl-0123 entry 110
#   denies udp/30303 from 10.0.4.0/23" — a citation we can send them.
#
# WHAT MAKES IT DIFFERENT FROM READING THE RULES BY EYE
#   1. NACLs are evaluated IN RULE-NUMBER ORDER AND THE FIRST MATCH WINS. A
#      `deny` at 90 beats an `allow` at 100, and that is invisible when you read
#      a console listing sorted by anything else. This script evaluates in order.
#   2. NACLs are STATELESS, so a permitted flow still fails unless the RETURN
#      path over the ephemeral range is permitted too. Half the failures in this
#      class are missing return rules (#34 F-3 exists only for this reason).
#   3. TCP AND UDP ARE CHECKED SEPARATELY. F-1 needs both. With 30303/TCP open
#      and 30303/UDP closed, statically-configured peers still connect and the
#      chain LOOKS FINE — discovery is simply dead, and nothing surfaces it until
#      something depends on it.
#   4. PARTIAL CIDR OVERLAP IS REPORTED AS ITS OWN VERDICT, not rounded to pass
#      or fail. A rule covering two of our three AZ subnets produces a chain that
#      works until the scheduler puts a validator in the third zone.
#
# Usage:
#   scripts/preflight/verify-subnet-rules.sh --region af-south-1 \
#       --node subnet-a,subnet-b,subnet-c \
#       --lb   subnet-d,subnet-e,subnet-f \
#       [--endpoint subnet-g,...] [--data subnet-h,...] [--runner subnet-i] \
#       [--node-sg sg-xxx] [--proxy 10.9.0.0/24:3128] [--sipn 10.200.0.0/16]
#
# The subnet IDs come from the cluster hand-over (#34's three placement facts).
# Anything not supplied is SKIPPED AND COUNTED, never passed — see the summary.
# =============================================================================
set -euo pipefail

REGION=""; NODE=""; LB=""; ENDPOINT=""; DATA=""; RUNNER=""; NODE_SG=""
PROXY=""; SIPN=""; P2P_PORT=30303; RPC_PORTS="8545-8546"; METRICS_PORT=9545; PG_PORT=5432

while [[ $# -gt 0 ]]; do
  case "$1" in
    --region)   REGION="$2"; shift 2 ;;
    --node)     NODE="$2"; shift 2 ;;
    --lb)       LB="$2"; shift 2 ;;
    --endpoint) ENDPOINT="$2"; shift 2 ;;
    --data)     DATA="$2"; shift 2 ;;
    --runner)   RUNNER="$2"; shift 2 ;;
    --node-sg)  NODE_SG="$2"; shift 2 ;;
    --proxy)    PROXY="$2"; shift 2 ;;
    --sipn)     SIPN="$2"; shift 2 ;;
    -h|--help)  sed -n '2,46p' "$0"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

[[ -n "$REGION" ]] || { echo "usage: verify-subnet-rules.sh --region <r> --node <ids> --lb <ids> [...]  (-h for detail)" >&2; exit 2; }
[[ -n "$NODE"   ]] || { echo "--node is required: it is where our pods run, and F-1 is the flow that matters most." >&2; exit 2; }
command -v aws >/dev/null || { echo "aws CLI is required" >&2; exit 1; }
command -v jq  >/dev/null || { echo "jq is required" >&2; exit 1; }

PASS=0; FAIL=0; WARN=0; SKIP=0
ok()   { printf '  \033[32mPASS\033[0m  %s\n' "$*"; PASS=$((PASS+1)); }
bad()  { printf '  \033[31mFAIL\033[0m  %s\n' "$*" >&2; FAIL=$((FAIL+1)); }
warn() { printf '  \033[33mWARN\033[0m  %s\n' "$*"; WARN=$((WARN+1)); }
skip() { printf '  \033[36mSKIP\033[0m  %s\n' "$*"; SKIP=$((SKIP+1)); }
sec()  { printf '\n\033[1m%s\033[0m\n' "$*"; }
note() { printf '        %s\n' "$*"; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
A=(aws --region "$REGION")

ALL_IDS="$(printf '%s,%s,%s,%s,%s' "$NODE" "$LB" "$ENDPOINT" "$DATA" "$RUNNER" | tr ',' '\n' | grep -v '^$' | sort -u | tr '\n' ' ')"

printf '\n=== #34 subnet rules, %s ===\n' "$REGION"

# -----------------------------------------------------------------------------
# One describe-subnets and one describe-network-acls. Flatten both to TSV so the
# evaluation is pure arithmetic with no further API calls.
# -----------------------------------------------------------------------------
# shellcheck disable=SC2086
"${A[@]}" ec2 describe-subnets --subnet-ids $ALL_IDS \
  --query 'Subnets[].{id:SubnetId,cidr:CidrBlock,az:AvailabilityZoneId}' --output json > "$TMP/subnets.json" \
  || { echo "cannot describe the supplied subnets — wrong region, or no ec2:DescribeSubnets" >&2; exit 1; }

# shellcheck disable=SC2086
"${A[@]}" ec2 describe-network-acls --filters "Name=association.subnet-id,Values=$(echo $ALL_IDS | tr ' ' ',')" \
  --output json > "$TMP/nacls.json" 2>/dev/null || echo '{"NetworkAcls":[]}' > "$TMP/nacls.json"

# subnet_id -> cidr
cidr_of() { jq -r --arg i "$1" '.[] | select(.id==$i) | .cidr' "$TMP/subnets.json"; }
# comma list -> space-separated CIDRs
cidrs_of() { local out=(); for s in ${1//,/ }; do out+=("$(cidr_of "$s")"); done; printf '%s\n' "${out[@]}"; }
# subnet_id -> the NACL governing it
nacl_of() { jq -r --arg i "$1" '.NetworkAcls[] | select(any(.Associations[]; .SubnetId==$i)) | .NetworkAclId' "$TMP/nacls.json" | head -1; }

# Flatten every NACL entry: aclid \t egress \t rulenum \t proto \t from \t to \t cidr \t action
jq -r '.NetworkAcls[] as $a | $a.Entries[] |
  [ $a.NetworkAclId,
    (if .Egress then "1" else "0" end),
    (.RuleNumber|tostring),
    .Protocol,
    ((.PortRange.From // 0)|tostring),
    ((.PortRange.To   // 65535)|tostring),
    (.CidrBlock // "0.0.0.0/0"),
    .RuleAction ] | @tsv' "$TMP/nacls.json" | sort -t$'\t' -k1,1 -k2,2 -k3,3n > "$TMP/entries.tsv"

NACL_COUNT="$(jq '.NetworkAcls | length' "$TMP/nacls.json")"
DEFAULT_ONLY=0
if [[ "$NACL_COUNT" -eq 0 ]]; then
  warn "no NACLs are associated with the supplied subnets"
  note "Either the cloud team uses security groups only (question C — a real answer), or"
  note "we were given the wrong subnet IDs. NACL evaluation below is SKIPPED, not passed."
  DEFAULT_ONLY=1
elif ! grep -qv $'\t''deny$' "$TMP/entries.tsv" 2>/dev/null && false; then
  : # placeholder; the permissive check is below
fi

# A NACL whose only rules are allow-all is the AWS default NACL. Saying so
# matters: it means there is no L3 boundary at all, which is a finding in its own
# right even though every flow "passes".
PERMISSIVE_ACLS="$(awk -F'\t' '$8=="allow" && $4=="-1" && $7=="0.0.0.0/0" {print $1}' "$TMP/entries.tsv" | sort -u)"

# -----------------------------------------------------------------------------
# nacl_eval <aclid> <egress 0|1> <proto tcp|udp> <port> <counterparty cidr>
# -----------------------------------------------------------------------------
# Evaluates IN RULE-NUMBER ORDER and returns the FIRST match, which is what AWS
# does. Prints: "<allow|deny|none>\t<rulenum>\t<cidr>\t<coverage full|partial>"
#
# Coverage is reported rather than collapsed. A rule whose CIDR only PARTIALLY
# overlaps the counterparty permits some addresses and not others — which, for
# validators spread across three AZs, is a chain that works until the scheduler
# uses the third zone. Rounding that to PASS is how a check becomes misleading.
nacl_eval() {
  local acl="$1" eg="$2" proto="$3" port="$4" cidr="$5"
  awk -F'\t' -v acl="$acl" -v eg="$eg" -v proto="$proto" -v port="$port" -v q="$cidr" '
    function ip2int(ip, p) { split(ip, p, "."); return p[1]*16777216 + p[2]*65536 + p[3]*256 + p[4] }
    function net(c, a) { split(c, a, "/"); return ip2int(a[1]) }
    function bits(c, a) { split(c, a, "/"); return a[2]+0 }
    function lo(c) { return net(c) }
    function hi(c) { return net(c) + 2^(32 - bits(c)) - 1 }
    BEGIN {
      pnum = (proto == "tcp" ? 6 : (proto == "udp" ? 17 : -1))
      qlo = lo(q); qhi = hi(q)
      found = 0
    }
    $1 == acl && $2 == eg {
      ep = $4
      # protocol: "-1" matches everything and its port range is ignored by AWS
      if (ep != "-1" && ep+0 != pnum) next
      if (ep != "-1") { if (port+0 < $5+0 || port+0 > $6+0) next }
      elo = lo($7); ehi = hi($7)
      if (ehi < qlo || elo > qhi) next          # no overlap at all
      cover = (elo <= qlo && ehi >= qhi) ? "full" : "partial"
      if (!found) { print $8 "\t" $3 "\t" $7 "\t" cover "\t" $5 "-" $6; found = 1; exit }
    }
    END { if (!found) print "none\t-\t-\t-\t-" }
  ' "$TMP/entries.tsv"
}

# -----------------------------------------------------------------------------
# check_flow <flow> <desc> <src cidr> <src subnet> <dst cidr> <dst subnet>
#            <proto> <port> <return-mode>
# -----------------------------------------------------------------------------
# A flow needs FOUR things to work through stateless ACLs, and a missing return
# rule is as fatal as a missing forward rule while being far less obvious:
#   source egress permits (dst, port) · dest ingress permits (src, port)
#   + the return path, whose PORT DEPENDS ON THE PROTOCOL.
#
# RETURN MODES — getting this wrong produces false positives, and did:
#   eph   the reply goes to the initiator's EPHEMERAL port. The normal
#         client/server case: TCP generally, and UDP where the client binds a
#         random port. Checks 1024-65535 in both directions.
#   same  the reply comes back to the SAME port. devp2p discovery is like this —
#         Besu sends UDP from its own bound 30303 to the peer's 30303, so the
#         forward rules already cover the reply and demanding an ephemeral rule
#         reports a failure that does not exist. The first version of this script
#         used `eph` for every flow and declared F-1 UDP blocked against a
#         fixture that was correct.
#   none  no return check (the counterparty is outside the NACL's scope).
check_flow() {
  local flow="$1" desc="$2" scidr="$3" ssub="$4" dcidr="$5" dsub="$6" proto="$7" port="$8" ret="${9:-eph}"
  local sacl dacl r verdict rule rcidr cover rports label problems=() broad=() incidental=() unchecked=()

  [[ -n "$scidr" && -n "$dcidr" ]] || { skip "$flow $desc — subnet not supplied"; return; }
  sacl="$(nacl_of "$ssub")"; dacl="$(nacl_of "$dsub")"
  if [[ -z "$sacl" && -z "$dacl" ]]; then
    skip "$flow $desc — no NACL on either subnet (security groups only?)"
    return
  fi

  for probe in "egress:$sacl:$dcidr:$port:forward out" "ingress:$dacl:$scidr:$port:forward in"; do
    IFS=: read -r dir acl target p label <<<"$probe"
    # An unevaluable side is NOT a pass. Every real subnet has a NACL (the VPC's
    # default one if nothing else), so reaching this means we were handed a
    # subnet we cannot see — and skipping it silently would have made the whole
    # flow report PASS on the strength of one half.
    if [[ -z "$acl" ]]; then
      unchecked+=("no NACL found for the $dir side ($label) — this half was NOT evaluated")
      continue
    fi
    r="$(nacl_eval "$acl" "$([[ $dir == egress ]] && echo 1 || echo 0)" "$proto" "$p" "$target")"
    IFS=$'\t' read -r verdict rule rcidr cover rports <<<"$r"
    case "$verdict" in
      allow)
        [[ "$cover" == full ]] || problems+=("PARTIAL: $acl $dir rule $rule allows only $rcidr of $target ($label)")
        [[ "$rcidr" == "0.0.0.0/0" ]] && broad+=("$acl $dir rule $rule is 0.0.0.0/0 ($label)")
        # A SERVICE port permitted by a rule whose range is the ephemeral range
        # is permitted INCIDENTALLY: that rule exists to carry return traffic,
        # and it happens to cover this port because every port this platform
        # listens on is inside 1024-65535. Removing the flow's own rule would
        # not change the verdict, so the pass says nothing about the flow.
        [[ "${rports%%-*}" -le 1024 && "${rports##*-}" -ge 65535 && "$p" -ge 1024 ]] \
          && incidental+=("$acl $dir rule $rule covers $p only because its range is $rports ($label)")
        ;;
      deny)  problems+=("DENIED by $acl $dir rule $rule ($rcidr) — $label") ;;
      none)  problems+=("NO RULE permits $proto/$p $dir on $acl for $target — the implicit deny applies ($label)") ;;
    esac
  done

  # `same`-mode return is already proven by the forward probes above: the reply
  # travels to the same port, so the same two rules carry it.
  if [[ "$ret" == "eph" ]]; then
    for probe in "egress:$dacl:$scidr:1024:return out" "ingress:$sacl:$dcidr:1024:return in"; do
      IFS=: read -r dir acl target p label <<<"$probe"
      if [[ -z "$acl" ]]; then
        unchecked+=("no NACL for the return $dir side ($label) — NOT evaluated")
        continue
      fi
      r="$(nacl_eval "$acl" "$([[ $dir == egress ]] && echo 1 || echo 0)" "$proto" "$p" "$target")"
      IFS=$'\t' read -r verdict rule rcidr cover rports <<<"$r"
      case "$verdict" in
        allow)
          [[ "$cover" == full ]] || problems+=("PARTIAL return: $acl $dir rule $rule covers only $rcidr ($label)")
          [[ "$rcidr" == "0.0.0.0/0" ]] && broad+=("$acl $dir rule $rule is 0.0.0.0/0 ($label)")
          ;;
        deny)  problems+=("RETURN DENIED by $acl $dir rule $rule ($rcidr) — $label") ;;
        none)  problems+=("NO RETURN RULE: $acl $dir has nothing for $proto/1024-65535 to $target ($label)") ;;
      esac
    done
  fi

  if [[ ${#problems[@]} -eq 0 && ${#unchecked[@]} -gt 0 ]]; then
    warn "$flow $desc ($proto/$port) — PARTLY UNEVALUATED"
    for u in "${unchecked[@]}"; do note "$u"; done
    note "Not a pass: one direction of this flow was never checked."
  elif [[ ${#problems[@]} -eq 0 && ${#incidental[@]} -gt 0 ]]; then
    warn "$flow $desc ($proto/$port) — permitted INCIDENTALLY"
    for i in "${incidental[@]}"; do note "$i"; done
    note "A stateless ACL that permits ephemeral return traffic has, by construction,"
    note "also permitted inbound connections to every service on a high port — and"
    note "ours are all high (30303, 8545, 8546, 9545, 5432). So this flow works, but"
    note "the NACL is not what is permitting it deliberately, and tightening the"
    note "flow's own rule would change nothing. The real boundary here is the"
    note "security group (#6) and NetworkPolicy (#35), not this."
  elif [[ ${#problems[@]} -eq 0 ]]; then
    if [[ ${#broad[@]} -gt 0 ]]; then
      # A pass carried by an 0.0.0.0/0 rule is not evidence ABOUT THIS FLOW: the
      # same rule would permit anything, so removing the flow's own rule would
      # not change the verdict. Say so, or the run reads as proof it is not.
      warn "$flow $desc ($proto/$port) — permitted, but only by a 0.0.0.0/0 rule"
      for b in "${broad[@]}"; do note "$b"; done
      note "This is NOT evidence that $flow is specifically permitted: that rule would"
      note "carry any traffic. Ask whether the broad rule is intended before relying on it."
    else
      ok "$flow $desc ($proto/$port)"
    fi
  else
    bad "#34 $flow BLOCKED: $desc ($proto/$port)"
    for p in "${problems[@]}"; do note "$p"; done
  fi
}

# =============================================================================
# The flows. Numbering follows #34 exactly; do not renumber here.
# =============================================================================
NODE_CIDRS=($(cidrs_of "$NODE")); NODE_IDS=(${NODE//,/ })
LB_CIDRS=();  LB_IDS=();  [[ -n "$LB" ]]       && { LB_CIDRS=($(cidrs_of "$LB"));             LB_IDS=(${LB//,/ }); }
EP_CIDRS=();  EP_IDS=();  [[ -n "$ENDPOINT" ]] && { EP_CIDRS=($(cidrs_of "$ENDPOINT"));       EP_IDS=(${ENDPOINT//,/ }); }
DT_CIDRS=();  DT_IDS=();  [[ -n "$DATA" ]]     && { DT_CIDRS=($(cidrs_of "$DATA"));           DT_IDS=(${DATA//,/ }); }
RN_CIDR="";   [[ -n "$RUNNER" ]]               && RN_CIDR="$(cidr_of "$RUNNER")"

sec "F-1  validator peer-to-peer — BOTH protocols, every AZ pair"
note "Validators are deliberately spread across three AZs, so every pair crosses"
note "a subnet boundary. A blocked F-1 gives a peer count of zero and nothing else."
for i in "${!NODE_IDS[@]}"; do
  for j in "${!NODE_IDS[@]}"; do
    [[ "$i" == "$j" ]] && continue
    # RLPx over TCP: the initiator uses an ephemeral source port, so the reply
    # needs an ephemeral return rule.
    check_flow "F-1" "${NODE_CIDRS[$i]} -> ${NODE_CIDRS[$j]} [tcp]" \
      "${NODE_CIDRS[$i]}" "${NODE_IDS[$i]}" "${NODE_CIDRS[$j]}" "${NODE_IDS[$j]}" tcp "$P2P_PORT" eph
    # devp2p discovery over UDP is SYMMETRIC — Besu sends from its own bound
    # 30303 to the peer's 30303 — so the forward rules carry the reply and an
    # ephemeral return rule is not required. Demanding one reports a blockage
    # that does not exist.
    check_flow "F-1" "${NODE_CIDRS[$i]} -> ${NODE_CIDRS[$j]} [udp]" \
      "${NODE_CIDRS[$i]}" "${NODE_IDS[$i]}" "${NODE_CIDRS[$j]}" "${NODE_IDS[$j]}" udp "$P2P_PORT" same
  done
done
note "If TCP passed and UDP failed above: statically-configured peers will still"
note "connect and the chain will look healthy, with discovery dead. That is the"
note "partially-silent case #34 calls out."

sec "F-2 / F-3  RPC through the NLBs, and the stateless return path"
if [[ ${#LB_IDS[@]} -eq 0 ]]; then
  skip "F-2/F-3 — no --lb subnets supplied; the NLB path was NOT verified"
else
  for i in "${!LB_IDS[@]}"; do
    for j in "${!NODE_IDS[@]}"; do
      check_flow "F-2" "lb ${LB_CIDRS[$i]} -> pods ${NODE_CIDRS[$j]}" \
        "${LB_CIDRS[$i]}" "${LB_IDS[$i]}" "${NODE_CIDRS[$j]}" "${NODE_IDS[$j]}" tcp 8545 eph
    done
  done
  note "This is also #33's silent failure: if it is the node SECURITY GROUP rather"
  note "than the NACL, the symptom is identical — targets unhealthy, nothing named."
fi

sec "F-5  AWS APIs via the interface endpoints"
if [[ ${#EP_IDS[@]} -eq 0 ]]; then
  skip "F-5 — no --endpoint subnets supplied"
  note "A blocked F-5 is the signature failure of this VPC: every AWS SDK call HANGS"
  note "until timeout rather than erroring. Worth supplying the subnet IDs."
else
  for i in "${!NODE_IDS[@]}"; do
    check_flow "F-5" "pods ${NODE_CIDRS[$i]} -> endpoints ${EP_CIDRS[0]}" \
      "${NODE_CIDRS[$i]}" "${NODE_IDS[$i]}" "${EP_CIDRS[0]}" "${EP_IDS[0]}" tcp 443 eph
  done
  [[ -n "$RN_CIDR" ]] && check_flow "F-5" "admin instance -> endpoints" \
    "$RN_CIDR" "$RUNNER" "${EP_CIDRS[0]}" "${EP_IDS[0]}" tcp 443 eph
fi

sec "F-6  S3 gateway — image layers, Terraform state, the tool bundle"
note "A NACL CANNOT reference a prefix list (#34 F-6 says so), so the rule must"
note "cover S3's regional ranges. A blocked F-6 stalls a pull MID-LAYER: ECR serves"
note "the manifest, S3 serves the bytes, so the pull starts and then stops."
S3_PL="$("${A[@]}" ec2 describe-prefix-lists --filters "Name=prefix-list-name,Values=com.amazonaws.${REGION}.s3" \
          --query 'PrefixLists[0].Cidrs' --output json 2>/dev/null || echo 'null')"
if [[ "$S3_PL" == "null" || -z "$S3_PL" ]]; then
  warn "F-6 — could not read the S3 prefix list; cannot evaluate"
else
  S3_N="$(jq 'length' <<<"$S3_PL")"
  for i in "${!NODE_IDS[@]}"; do
    acl="$(nacl_of "${NODE_IDS[$i]}")"; [[ -n "$acl" ]] || continue
    blocked=0; first=""
    while IFS= read -r c; do
      r="$(nacl_eval "$acl" 1 tcp 443 "$c")"
      v="$(cut -f1 <<<"$r")"
      [[ "$v" == allow ]] || { blocked=$((blocked+1)); [[ -z "$first" ]] && first="$c ($(cut -f1 <<<"$r"))"; }
    done < <(jq -r '.[]' <<<"$S3_PL")
    if [[ "$blocked" -eq 0 ]]; then
      ok "F-6 ${NODE_CIDRS[$i]} -> all $S3_N S3 ranges on 443"
    else
      bad "#34 F-6 BLOCKED: ${NODE_CIDRS[$i]} cannot reach $blocked of $S3_N S3 ranges on 443"
      note "first unreachable: $first"
      note "Covering 0.0.0.0/0 on 443 egress is what most teams do here; the"
      note "alternative is enumerating the ranges, which change over time."
    fi
  done
fi

sec "F-9  explorer database (#37)"
if [[ ${#DT_IDS[@]} -eq 0 ]]; then
  skip "F-9 — no --data subnets supplied (in-cluster Postgres needs no rule)"
else
  for i in "${!NODE_IDS[@]}"; do
    check_flow "F-9" "pods ${NODE_CIDRS[$i]} -> data ${DT_CIDRS[0]}" \
      "${NODE_CIDRS[$i]}" "${NODE_IDS[$i]}" "${DT_CIDRS[0]}" "${DT_IDS[0]}" tcp "$PG_PORT" eph
  done
fi

sec "F-8  administrative instance -> egress proxy (R-10)"
if [[ -z "$PROXY" || -z "$RN_CIDR" ]]; then
  skip "F-8 — needs --proxy <cidr>:<port> and --runner <subnet>"
else
  PC="${PROXY%%:*}"; PP="${PROXY##*:}"
  racl="$(nacl_of "$RUNNER")"
  if [[ -z "$racl" ]]; then
    skip "F-8 — no NACL on the administrative instance's subnet"
  else
    r="$(nacl_eval "$racl" 1 tcp "$PP" "$PC")"
    IFS=$'\t' read -r v rule rc cov <<<"$r"
    if [[ "$v" == allow ]]; then
      ok "F-8 admin -> $PC:$PP (rule $rule, $cov coverage)"
    else
      bad "#34 F-8 BLOCKED: admin instance cannot reach the egress proxy $PC:$PP ($v)"
      note "Without it the Octopus polling Tentacle cannot register (CD-55/CD-57) and"
      note "every deployment stops — but the chain itself is unaffected, so this one"
      note "fails loudly in the pipeline rather than silently in the ledger."
    fi
  fi
fi

sec "F-10  DNS"
note "Network ACLs do NOT apply to the Amazon-provided resolver at the VPC+2"
note "address, so there is usually nothing to check. Listed because if pods"
note "resolve through anything else — a forwarder, a corporate resolver — it DOES"
note "need a rule, and a DNS failure here presents as F27's non-deterministic"
note "startup race rather than as a name-resolution error."
skip "F-10 — not evaluable from rules alone; verify-endpoints.sh covers resolution"

# -----------------------------------------------------------------------------
# #33 — the node security group, if we were given it.
# -----------------------------------------------------------------------------
# Security groups are STATEFUL, so only the forward direction matters and egress
# defaults to allow-all. Evaluation is "does ANY rule permit", with no ordering
# and no deny rules — the opposite of a NACL, which is why this is separate code
# rather than the same loop.
sec "#33  node security group (stateful — forward direction only)"
if [[ -z "$NODE_SG" ]]; then
  skip "#33 — no --node-sg supplied. The node SG is THEIRS and it is the other half"
  note "of F-2: if it does not admit 8545-8546 from our NLB security groups, the"
  note "targets stay unhealthy forever with nothing naming a security group."
else
  SG="$("${A[@]}" ec2 describe-security-groups --group-ids "$NODE_SG" \
         --query 'SecurityGroups[0].IpPermissions' --output json 2>/dev/null || echo '[]')"
  for p in 8545 8546; do
    if jq -e --argjson p "$p" 'any(.[]; (.IpProtocol=="-1") or ((.FromPort // 0) <= $p and (.ToPort // 65535) >= $p))' <<<"$SG" >/dev/null; then
      ok "#33 node SG $NODE_SG admits $p"
    else
      bad "#33 VIOLATED: node SG $NODE_SG has no ingress rule covering $p"
      note "Our NLBs target POD IPs, so health checks arrive at this group. Ask for"
      note "ingress on 8545-8546 from our NLB security groups, or for Security Groups"
      note "for Pods so we attach our own and they touch nothing (question D)."
    fi
  done
  if jq -e 'any(.[]; .IpProtocol=="-1" and any(.IpRanges[]?; .CidrIp=="0.0.0.0/0"))' <<<"$SG" >/dev/null; then
    warn "#33 node SG $NODE_SG permits ALL protocols from 0.0.0.0/0"
    note "Every flow above will pass through it, so this check proves nothing about"
    note "the posture. Report it: on a shared cluster that is every tenant's reach."
  fi
fi

# -----------------------------------------------------------------------------
sec "Summary"
if [[ -n "$PERMISSIVE_ACLS" ]]; then
  warn "allow-all NACL(s): $(echo "$PERMISSIVE_ACLS" | tr '\n' ' ')"
  note "Every flow 'passes' because nothing is being enforced. That is a finding in"
  note "its own right — there is no L3 boundary on those subnets — and it means this"
  note "run has NOT demonstrated that the rules permit our flows, only that no rule"
  note "forbids them. Re-run against the real ruleset before relying on a pass."
fi
printf '\n=== %d passed, %d failed, %d warnings, %d skipped ===\n' "$PASS" "$FAIL" "$WARN" "$SKIP"
if [[ "$SKIP" -gt 0 ]]; then
  printf '\033[36m%d check(s) were SKIPPED and are NOT passes.\033[0m Supply the missing subnet IDs\n' "$SKIP"
  printf '(--lb, --endpoint, --data, --runner, --node-sg, --proxy) before treating the\n'
  printf 'flow table as verified. #34 asks the cloud team for exactly these placements.\n'
fi
[[ "$FAIL" -eq 0 ]] || { echo "Flows are blocked. Quote the #34 F-n citations above back to the cloud team." >&2; exit 1; }
