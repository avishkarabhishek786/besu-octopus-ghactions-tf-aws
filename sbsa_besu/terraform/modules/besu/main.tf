# =============================================================================
# modules/besu/main.tf
# -----------------------------------------------------------------------------
# Computes the network topology and drives the Helm releases:
#   * ONE besu-genesis release (a Job that generates keys + genesis, writes keys
#     to Secrets Manager, and publishes the genesis ConfigMap). helm waits for
#     the Job to COMPLETE before the node releases proceed.
#   * ONE besu-node release PER NODE (validators, bootnodes, RPC) so each pod
#     mounts only its own key. Release name == StatefulSet/Service name, which
#     makes the pod-0 DNS host deterministic and equal to the enode host every
#     other node is configured with.
#
# DETERMINISTIC NAMING / ORDERING
#   release  besu-validator-i  <-> secret besu-node-validator-i <-> pubkey i
#   host     besu-validator-i-0.besu-validator-i.<ns>.svc.<domain>:<p2p>
#   The genesis Job emits pubkeys in the SAME order it assigns the secrets, so
#   the node initContainer can zip pubkey[i] with host[i] into the enode list.
# =============================================================================

locals {
  validator_releases = [for i in range(1, var.validator_count + 1) : "besu-validator-${i}"]
  bootnode_releases  = [for i in range(1, var.bootnode_count + 1) : "besu-bootnode-${i}"]
  rpc_releases       = [for i in range(1, var.rpc_count + 1) : "besu-rpc-${i}"]
  # Stage 8: app-facing RPC pool releases (besu-app-rpc-1..J). Full Besu RPC
  # nodes INSIDE the chain cluster (A′) — separate identities from the SWIFT pool.
  app_rpc_releases = [for i in range(1, var.app_rpc_count + 1) : "besu-app-rpc-${i}"]
  # Stage 9: Blockscout explorer RPC pool releases (besu-explorer-rpc-1..E). Full
  # Besu RPC nodes INSIDE the cluster (ClusterIP only) — separate identities again.
  explorer_rpc_releases = [for i in range(1, var.explorer_rpc_count + 1) : "besu-explorer-rpc-${i}"]

  # Stable pod-0 DNS host of each node (headless service name == release name).
  host = {
    for r in concat(local.validator_releases, local.bootnode_releases, local.rpc_releases, local.app_rpc_releases, local.explorer_rpc_releases) :
    r => "${r}-0.${r}.${var.namespace}.svc.${var.cluster_domain}"
  }

  peers = {
    validators  = [for r in local.validator_releases : local.host[r]]
    bootnodes   = [for r in local.bootnode_releases : local.host[r]]
    rpc         = [for r in local.rpc_releases : local.host[r]]
    appRpc      = [for r in local.app_rpc_releases : local.host[r]]
    explorerRpc = [for r in local.explorer_rpc_releases : local.host[r]]
  }

  # release name => { role, secret } for the per-node for_each.
  nodes = merge(
    { for i, r in local.validator_releases : r => { role = "validator", secret = var.validator_secret_names[i] } },
    { for i, r in local.bootnode_releases : r => { role = "bootnode", secret = var.bootnode_secret_names[i] } },
    { for i, r in local.rpc_releases : r => { role = "rpc", secret = var.rpc_secret_names[i] } },
    { for i, r in local.app_rpc_releases : r => { role = "app-rpc", secret = var.app_rpc_secret_names[i] } },
    { for i, r in local.explorer_rpc_releases : r => { role = "explorer-rpc", secret = var.explorer_rpc_secret_names[i] } },
  )

  # H1 (upgrade fail-safety): validators are managed as their OWN helm_release with
  # lifecycle{ ignore_changes=[values] } so a routine `terraform apply` can NEVER
  # push a pod-template change (image / peers / resources / cert names / chart
  # version) to the consensus nodes in bulk and halt the chain. Non-consensus pools
  # stay in helm_release.node and are freely managed by Terraform (they hold no QBFT
  # quorum). Validator-affecting changes go ONLY through
  # scripts/maintenance/rolling-besu-apply.sh (one at a time, under the quorum gate);
  # the chart also pins validators to updateStrategy=OnDelete so even an out-of-band
  # change never auto-restarts a validator pod.
  validator_nodes    = { for r, n in local.nodes : r => n if n.role == "validator" }
  nonvalidator_nodes = { for r, n in local.nodes : r => n if n.role != "validator" }

  chart_dir = "${path.module}/../../../helm/charts"

  # Per-node Helm values, keyed by release name. Built ONCE and shared by BOTH node
  # resources (helm_release.node + helm_release.validator) so the two code paths
  # render byte-identical pod specs — only the Terraform lifecycle/k8s update policy
  # differs by role. The chart role-gates the appRpc/opsRpc/explorerRpc blocks, so it
  # is correct (and matches the prior behavior) to pass every block for every node.
  node_values = {
    for name, cfg in local.nodes : name => yamlencode({
      fullnameOverride     = name
      role                 = cfg.role
      besuImage            = var.besu_image
      toolsImage           = var.tools_image
      chainId              = var.chain_id
      p2pPort              = var.p2p_port
      rpcHttpPort          = var.rpc_http_port
      rpcWsPort            = var.rpc_ws_port
      metricsPort          = var.metrics_port
      clusterDomain        = var.cluster_domain
      nodeSecretName       = cfg.secret
      caCertSecretName     = var.ca_cert_secret_name
      secretsRegion        = var.region
      genesisConfigMapName = "besu-genesis"
      serviceAccountName   = "quorum-node-secrets-sa"
      storage              = { storageClassName = var.storage_class_name, size = "${var.data_volume_size_gib}Gi" }
      permissioning = {
        nodeMode                      = var.node_permissioning_mode
        accountMode                   = var.account_permissioning_mode # "off" | "local" (file-based accounts-allowlist — C6)
        accountAllowlistConfigMapName = var.account_allowlist_configmap_name
      }
      peers = local.peers
      # H23: host-allowlist is a settable value (no longer a hardcoded "*") — scope it to the RPC
      # SAN / service DNS per pool at go-live; default "*" preserves the verified access path.
      rpc = { apis = "ETH,NET,WEB3", hostAllowlist = var.rpc_host_allowlist }
      # H23: scope CORS. Default "none" — every RPC pool is server-to-server (Blockscout, Next.js
      # signer) or mTLS (SWIFT); the browser talks to the Next.js API, never Besu directly, so no
      # pool needs a permissive CORS origin. Was a hardcoded chart default of "*".
      corsOrigins = var.rpc_cors_origins
      # mTLS + method scoping (only takes effect for role=rpc; deep-merges with the
      # chart's mtls defaults for the secret names).
      mtls    = { enabled = var.rpc_mtls_enabled }
      rpcAuth = { mode = var.rpc_auth_mode }
      # Stage 8: app-rpc pool (only takes effect for role=app-rpc) — server-TLS + JWT.
      appRpc = {
        apis = "ETH,NET,WEB3"
        ws   = { enabled = var.app_rpc_ws_enabled }
        tls = {
          enabled                = var.app_rpc_tls_enabled
          keystoreSecret         = var.app_rpc_keystore_secret_name
          keystorePasswordSecret = var.app_rpc_keystore_password_secret_name
        }
        auth = {
          enabled         = var.app_rpc_auth_enabled
          jwtPubkeySecret = var.app_rpc_jwt_pubkey_secret_name
        }
      }
      # Stage 8: validator-internal ops listener (only takes effect for role=validator).
      opsRpc = {
        enabled         = var.ops_rpc_enabled
        jwtPubkeySecret = var.ops_rpc_jwt_pubkey_secret_name
        allowNoJwt      = var.ops_rpc_allow_no_jwt # H6: escape hatch for the JWT precondition
      }
      # D-39: hard one-validator-per-node. Role-gated in the chart, so passing it
      # for every node keeps this map byte-identical across both node resources.
      antiAffinity = { requireDistinctNodes = var.validator_require_distinct_nodes }
      # H6: per-role NetworkPolicy ingress lockdown (default disabled; see var.network_policy).
      networkPolicy = var.network_policy
      # Stage 9: explorer-rpc pool (only takes effect for role=explorer-rpc).
      explorerRpc = {
        apis = var.explorer_rpc_apis
        ws   = { enabled = var.explorer_rpc_ws_enabled }
      }
      # H11: QBFT 25<->26 wire-compat flag. Normally false; the rolling upgrade
      # script sets it via --set for a mixed-version window (validators are frozen
      # in Terraform, so this Terraform value only applies at first create).
      bft = { legacyProtocolEncoding = var.bft_legacy_protocol_encoding }
    })
  }
}

# -----------------------------------------------------------------------------
# GENESIS — one-shot bootstrap. wait=true blocks until the Job completes, so the
# node releases below only start once keys + the genesis ConfigMap exist.
# -----------------------------------------------------------------------------
resource "helm_release" "genesis" {
  count = var.deploy ? 1 : 0

  name             = "besu-genesis"
  chart            = "${local.chart_dir}/besu-genesis"
  namespace        = var.namespace
  create_namespace = true
  wait             = true
  timeout          = 600

  values = [yamlencode({
    namespace          = var.namespace
    images             = { besu = var.besu_image, tools = var.tools_image }
    chainId            = var.chain_id
    blockPeriodSeconds = var.block_period_seconds
    gasLimit           = var.gas_limit
    # F20 (deploy-test 2026-06-29): accounts to alloc a genesis BALANCE, decoupled
    # from permissioning. On a zero-gas chain (min-gas-price=0, zeroBaseFee) a tx
    # from a zero-balance account is NOT mined, so any tx originator (a SWIFT signing
    # account, or the app's signer EOA) must be funded here even when account
    # permissioning is OFF. Provide the addresses via the root genesis_funded_accounts.
    fundedAccounts = var.genesis_funded_accounts
    # C4: build extraData from the provided validator keys (see genesis job.yaml).
    providedValidatorKeys = var.use_provided_validator_keys
    validatorCount        = var.validator_count
    bootnodeCount         = var.bootnode_count
    rpcCount              = var.rpc_count
    appRpcCount           = var.app_rpc_count
    explorerRpcCount      = var.explorer_rpc_count
    p2pPort               = var.p2p_port
    permissioning = {
      accountMode             = var.account_permissioning_mode
      nodeMode                = var.node_permissioning_mode
      adminAccount            = var.permissioning_admin_account
      initialAccountAllowlist = var.initial_account_allowlist
    }
    # C6: names the live allowlist ConfigMap the nodes mount (accountMode=local). The
    # chart renders only <name>-seed; the genesis Job creates <name> from it if absent.
    accountAllowlist = { configMapName = var.account_allowlist_configmap_name }
    secrets = {
      region            = var.region
      validatorPrefix   = "besu-node-validator"
      bootnodePrefix    = "besu-node-bootnode"
      rpcPrefix         = "besu-node-rpc"
      appRpcPrefix      = "besu-node-app-rpc"
      explorerRpcPrefix = "besu-node-explorer-rpc"
    }
    serviceAccount       = { name = "besu-genesis-sa", roleArn = var.genesis_role_arn }
    podServiceAccount    = { name = "quorum-node-secrets-sa", roleArn = var.pod_role_arn }
    genesisConfigMapName = "besu-genesis"
    # H2: re-genesis guard. false (default) => the Job REFUSES to overwrite an
    # existing besu-genesis ConfigMap, so a re-run cannot republish a mismatched
    # genesis.json and brick the chain (validators would compute a genesis hash that
    # no longer matches their RocksDB). Set true ONLY for a deliberate, destructive
    # re-genesis (wipe node-key secrets + validator PVCs first). See backlog H2.
    allowRegenesis = var.allow_regenesis
  })]

  # H2: freeze the one-shot bootstrap. Genesis runs ONCE, on the first apply. After
  # that, ignore value changes — most importantly a besu_version bump flowing into
  # images.besu — so a routine `terraform apply` never upgrades the genesis release
  # and re-runs the Job over a live chain. Defense-in-depth with the Job's own
  # allowRegenesis ConfigMap guard (helm/charts/besu-genesis/templates/job.yaml).
  # A deliberate re-genesis is a manual, documented operation (state rm the release +
  # delete the ConfigMap + wipe node-key secrets + validator PVCs, then re-apply),
  # not a value flip — so ignoring values here does not block it. See backlog H2.
  lifecycle {
    ignore_changes = [values]
  }
}

# -----------------------------------------------------------------------------
# NON-CONSENSUS NODES — one release per bootnode / rpc / app-rpc / explorer-rpc.
# These cast NO QBFT votes, so Terraform manages them normally (a RollingUpdate
# can't lose quorum). wait=false: nodes take time to peer; verify with kubectl.
# -----------------------------------------------------------------------------
resource "helm_release" "node" {
  for_each = var.deploy ? local.nonvalidator_nodes : {}

  name             = each.key
  chart            = "${local.chart_dir}/besu-node"
  namespace        = var.namespace
  create_namespace = false
  wait             = false
  timeout          = 600

  values = [local.node_values[each.key]]

  depends_on = [helm_release.genesis]
}

# -----------------------------------------------------------------------------
# VALIDATORS (H1) — one release each, FROZEN from Terraform's perspective.
# -----------------------------------------------------------------------------
# lifecycle{ ignore_changes=[values] } means a routine `terraform apply` never
# re-renders or restarts a validator: a besu_version bump, an app_rpc/explorer
# scale (which rewrites local.peers), or any other shared-value edit is a
# structural no-op on the consensus set. The ONLY supported way to change a
# validator is scripts/maintenance/rolling-besu-apply.sh — a helm upgrade + an
# OnDelete pod delete, one validator at a time, gated on quorum + catch-up. This
# is the Terraform belt to the chart's OnDelete braces (statefulset.yaml).
# First-time CREATE still uses these values (ignore_changes only affects updates).
#
# MIGRATION: applies cleanly to a FRESH chain (first apply CREATES these). For an
# already-applied chain whose STATE still holds helm_release.node["besu-validator-N"],
# re-home each release in state BEFORE applying so it is moved, not destroyed+recreated
# (which would helm-uninstall+reinstall every validator at once → quorum lost → HALT).
# Do NOT hand-run `terraform state mv` per validator — use the idempotent, dry-run-first
# helper that discovers + moves them all (and leaves bootnode/rpc/app-rpc/explorer alone):
#   scripts/maintenance/migrate-h1-validator-split.sh            # dry-run (shows the moves)
#   scripts/maintenance/migrate-h1-validator-split.sh --apply    # then: terraform plan
# It is a safe no-op on a fresh/already-split state. No live prod chain exists yet, so
# fresh applies need none.
resource "helm_release" "validator" {
  for_each = var.deploy ? local.validator_nodes : {}

  name             = each.key
  chart            = "${local.chart_dir}/besu-node"
  namespace        = var.namespace
  create_namespace = false
  wait             = false
  timeout          = 600

  values = [local.node_values[each.key]]

  lifecycle {
    ignore_changes = [values]
  }

  depends_on = [helm_release.genesis]
}

# -----------------------------------------------------------------------------
# RPC EDGE — binds the RPC pods to the internal NLB target group (stage 4).
# Created only when deploying in-cluster AND a target group ARN was provided
# (i.e. modules/rpc-access built the NLB). Requires the AWS Load Balancer
# Controller (installed by modules/rpc-access; ordered via the root module
# depends_on) for the TargetGroupBinding CRD.
# -----------------------------------------------------------------------------
resource "helm_release" "rpc_edge" {
  count = var.deploy && var.rpc_target_group_arn != "" ? 1 : 0

  name             = "besu-rpc-edge"
  chart            = "${local.chart_dir}/besu-rpc-edge"
  namespace        = var.namespace
  create_namespace = false
  wait             = false
  timeout          = 300

  values = [yamlencode({
    namespace      = var.namespace
    rpcPort        = var.rpc_http_port
    targetGroupArn = var.rpc_target_group_arn
  })]

  depends_on = [helm_release.node]
}

# -----------------------------------------------------------------------------
# APP-RPC EDGE (stage 8) — binds the app-rpc pods to the SEPARATE app NLB target
# groups (HTTP + WS) from modules/rpc-access. Created only when deploying
# in-cluster AND the app HTTP target group ARN was provided.
# -----------------------------------------------------------------------------
resource "helm_release" "app_rpc_edge" {
  count = var.deploy && lookup(var.app_rpc_target_group_arns, "http", "") != "" ? 1 : 0

  name             = "besu-app-rpc-edge"
  chart            = "${local.chart_dir}/besu-app-rpc-edge"
  namespace        = var.namespace
  create_namespace = false
  wait             = false
  timeout          = 300

  values = [yamlencode({
    namespace          = var.namespace
    httpPort           = var.rpc_http_port
    wsPort             = var.rpc_ws_port
    wsEnabled          = var.app_rpc_ws_enabled
    httpTargetGroupArn = lookup(var.app_rpc_target_group_arns, "http", "")
    wsTargetGroupArn   = lookup(var.app_rpc_target_group_arns, "ws", "")
  })]

  depends_on = [helm_release.node]
}
