#!/usr/bin/env bash
# =============================================================================
# octopus/steps/workloads-incluster.sh   — besu-workloads, the in-cluster layer
# -----------------------------------------------------------------------------
# Runs ON THE IN-VPC EC2 RUNNER, as an Octopus polling-Tentacle worker (CD-57),
# with the runner's instance role — the only host that can reach the private
# EKS endpoint. besu-infra has already applied the chain root's AWS layer from
# a hosted worker; this applies the SAME root, on the SAME state, with
# deploy_in_cluster_resources=true (CD-53): the Secrets Store CSI driver and
# its AWS provider, the LB controller, kube-prometheus-stack, Fluent Bit,
# genesis, the Besu pools and Blockscout.
#
#   1. toolchain from the runner bundle — never a download: the pinned terraform
#      must already be there, and providers come from the bundle's filesystem
#      mirror (D-20); without it `terraform init` would hang on the registry;
#   2. init on the environment's state; fetch the deploy config from the
#      RUNNER's own secret (same content as Octopus's, which the runner's role
#      cannot read — runner-bundle.sh fills both);
#   3. F19 — the RPC server keystore, truststore and JWT keys, BEFORE any RPC
#      pod starts (node permissioning resolves the allowlist's enode DNS once
#      at startup, so a pool that boots late is rejected for good). Issued ONCE:
#      re-running issue-server-cert.sh rotates the cert under running pods;
#   4. plan -out with exactly besu-infra's variables (lib.sh chain_tf_vars) plus
#      deploy_in_cluster_resources=true, attached as an artefact;
#   5. CD-5 / H1 plan-safety gate: the plan may CREATE validator releases (a
#      first install — there is no running chain to halt) but must never update,
#      replace or delete one. H1's ignore_changes + OnDelete make that a no-op
#      by construction; this gate makes the construction checked, not assumed.
#      A validator change goes through besu-validators, one pod at a time;
#   6. apply THAT plan, then verify-deployed.sh (four validators Ready on four
#      distinct nodes — the count, never the absence of errors, D-36).
#
# Environment (Octopus): BESU_ENV BESU_STATE_BUCKET BESU_STATE_REGION
#   BESU_CHAIN_EXTRA_ARGS AWS_REGION
#   BESU_VALIDATOR_COUNT  (default 4)
# The cluster and namespace come from the chain root's outputs, not from Octopus
# variables, so they cannot disagree with what was just applied.
# =============================================================================
set -euo pipefail

PKG="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)" # the extracted package = the sbsa_besu tree
: "${BESU_ENV:?}" "${BESU_STATE_BUCKET:?}" "${BESU_STATE_REGION:?}" "${AWS_REGION:?}"
ENV_LC="$(tr '[:upper:]' '[:lower:]' <<<"$BESU_ENV")"
export AWS_REGION

# shellcheck source=../../scripts/lib/common.sh
source "$PKG/scripts/lib/common.sh"
# shellcheck source=lib.sh
source "$PKG/octopus/steps/lib.sh"

# --- 1. the runner's toolchain (a Tentacle step is not a login shell) ---------
TOOLS=/usr/local/besu-tools
[[ -d "$TOOLS/bin" ]] || die "no $TOOLS/bin — this step must run on the In-VPC EC2 Runner (Besu.RunnerPool)"
export JAVA_HOME="$TOOLS/jvm" PATH="$TOOLS/bin:$TOOLS/jvm/bin:$PATH"
[[ -f "$TOOLS/terraformrc" ]] \
  || die "no provider mirror in the runner bundle (D-20): terraform init would hang on registry.terraform.io. Re-run besu-infra (runner bundle) and recreate the runner"
export TF_CLI_CONFIG_FILE="$TOOLS/terraformrc"
want="$(tool_version terraform)"
have="$(terraform version -json | python3 -c 'import json,sys;print(json.load(sys.stdin)["terraform_version"])')"
# install_pinned_terraform would DOWNLOAD on a mismatch — a hang in here.
[[ "$have" == "$want" ]] || die "runner terraform is $have, the pin is $want — rebuild the runner bundle"
terraform version | sed -n 1p

# --- 2. state + this environment's config ------------------------------------
init_root chain
cd "$PKG/terraform/chain"
RUNNER_SECRET="$(terraform output -raw runner_deploy_config_secret)"
DEPLOY_CONFIG_SECRET="$RUNNER_SECRET" bash "$PKG/scripts/runner/fetch-deploy-config.sh"
[[ -f "../environments/${ENV_LC}/chain.tfvars" ]] || die "deploy config has no environments/${ENV_LC}/chain.tfvars"
chain_tf_vars

# --- 3. F19: RPC server mTLS material, once -----------------------------------
if aws secretsmanager get-secret-value --secret-id besu-node-rpc-keystore \
  --query 'length(SecretString)' --output text >/dev/null 2>&1; then
  ok "RPC server keystore already issued — not rotating it (re-issue deliberately with scripts/pki/issue-server-cert.sh)"
else
  RPC_HOSTNAME="$(sed -n 's/^[[:space:]]*swift_rpc_hostname[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p' \
    "../environments/${ENV_LC}/chain.tfvars" | tail -1)"
  [[ -n "$RPC_HOSTNAME" ]] || die "swift_rpc_hostname is not set in environments/${ENV_LC}/chain.tfvars — the server cert's CN/SAN"
  log "F19: issuing the RPC server keystore for $RPC_HOSTNAME before any RPC pod starts"
  RPC_HOSTNAME="$RPC_HOSTNAME" bash "$PKG/scripts/pki/issue-server-cert.sh"
fi

# --- 4. plan, recorded ---------------------------------------------------------
terraform plan -input=false -no-color "${CHAIN_VARS[@]}" -var deploy_in_cluster_resources=true \
  -out=incluster.plan | tee incluster.plan.txt
if command -v new_octopusartifact >/dev/null 2>&1; then
  new_octopusartifact "$PWD/incluster.plan.txt" "chain-incluster-${ENV_LC}.plan.txt"
fi

# --- 5. CD-5 / H1: never touch an existing validator release ------------------
terraform show -json incluster.plan | python3 -c '
import json, sys
bad = [(c["address"], c["change"]["actions"])
       for c in json.load(sys.stdin).get("resource_changes", [])
       if ".helm_release.validator" in c["address"]
       and c["change"]["actions"] not in (["no-op"], ["create"], ["read"])]
for a, act in bad:
    print(f"REFUSED: {a}: {act}", file=sys.stderr)
sys.exit(1 if bad else 0)
' || die "CD-5: this plan would change an existing validator release — all four restart together, quorum is lost. Validators change only through besu-validators (rolling-besu-apply.sh)"
ok "CD-5 plan-safety: no existing validator release is changed"

# --- 6. apply exactly what was recorded, then assert the count -----------------
terraform apply -input=false -no-color incluster.plan

CLUSTER="$(terraform output -raw eks_cluster_name)"
NAMESPACE="$(terraform output -raw besu_namespace)"
export KUBECONFIG
KUBECONFIG="$(mktemp)"
aws eks update-kubeconfig --region "$AWS_REGION" --name "$CLUSTER" --kubeconfig "$KUBECONFIG" >/dev/null
command -v jq >/dev/null || die "verify-deployed.sh needs jq, which is not on this runner — the deployment applied, but its assertions did NOT run"
bash "$PKG/scripts/validation/verify-deployed.sh" -n "$NAMESPACE" -N "${BESU_VALIDATOR_COUNT:-4}"
