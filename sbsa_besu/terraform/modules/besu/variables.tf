# =============================================================================
# modules/besu/variables.tf
# -----------------------------------------------------------------------------
# Drives the stage-3 Besu workloads via Helm: the besu-genesis bootstrap Job
# and one besu-node release PER NODE (validators, bootnodes, RPC). This module
# uses the helm provider (inherited from root) and therefore needs a PRIVATE
# path to the EKS endpoint — it is gated by `deploy` (= deploy_in_cluster_resources)
# and is meant to run from the In-VPC EC2 Runner.
# =============================================================================

variable "deploy" {
  description = "Master gate. When false (laptop apply against the private endpoint), NO Helm releases are created. Set true from the In-VPC EC2 Runner."
  type        = bool
  default     = false
}

variable "namespace" {
  description = "Kubernetes namespace for all Besu workloads."
  type        = string
  default     = "besu"
}

variable "region" {
  description = "Region the secrets live in (passed to the SecretProviderClass + genesis Job)."
  type        = string
}

# --- Images (pinned) ---------------------------------------------------------
variable "besu_image" {
  description = "Fully-qualified Besu image (repository:tag), e.g. hyperledger/besu:26.6.1."
  type        = string
}

variable "tools_image" {
  description = "Multi-tool image (kubectl + aws-cli + jq) used by the genesis publish step and the node initContainer."
  type        = string
  default     = "alpine/k8s:1.30.13"
}

# --- Chain / QBFT ------------------------------------------------------------
variable "chain_id" {
  type = number
}

variable "block_period_seconds" {
  type    = number
  default = 5
}

variable "gas_limit" {
  type    = string
  default = "0x1fffffffffffff"

  validation {
    # H12: must be a 0x-prefixed hex string — a malformed value produces an invalid genesis.
    condition     = can(regex("^0x[0-9a-fA-F]+$", var.gas_limit))
    error_message = "gas_limit must be a 0x-prefixed hex string (e.g. 0x1fffffffffffff)."
  }
}

# --- Topology ----------------------------------------------------------------
variable "validator_count" {
  type = number

  validation {
    # H12: QBFT N=3F+1, N>=4 (defense-in-depth; the root var validates the same).
    condition     = var.validator_count >= 4 && (var.validator_count - 1) % 3 == 0
    error_message = "validator_count must be >= 4 and of the form 3F+1 (4, 7, 10, ...)."
  }
}

variable "bootnode_count" {
  type = number
}

variable "rpc_count" {
  type = number
}

variable "app_rpc_count" {
  description = "Stage 8: number of app-rpc pool nodes (besu-app-rpc-1..J). 0 = app layer not deployed."
  type        = number
  default     = 0
}

variable "explorer_rpc_count" {
  description = "Stage 9: number of explorer-rpc pool nodes (besu-explorer-rpc-1..E) for Blockscout. 0 = explorer not deployed."
  type        = number
  default     = 0
}

variable "explorer_rpc_apis" {
  description = "Stage 9: Besu RPC namespaces on the explorer-rpc pool. DEBUG/TRACE give Blockscout internal-transaction support; ClusterIP-only so this never reaches an edge."
  type        = string
  default     = "ETH,NET,WEB3,DEBUG,TRACE"
}

variable "explorer_rpc_ws_enabled" {
  description = "Stage 9: expose WS (eth_subscribe) on the explorer-rpc pool for Blockscout realtime updates."
  type        = bool
  default     = true
}

# --- Secret names (from modules/secrets) -------------------------------------
variable "validator_secret_names" {
  type = list(string)
}

variable "bootnode_secret_names" {
  type = list(string)
}

variable "rpc_secret_names" {
  type = list(string)
}

variable "app_rpc_secret_names" {
  description = "Stage 8: ordered app-rpc node-key secret names (from modules/secrets)."
  type        = list(string)
  default     = []
}

variable "explorer_rpc_secret_names" {
  description = "Stage 9: ordered explorer-rpc node-key secret names (from modules/secrets)."
  type        = list(string)
  default     = []
}

variable "ca_cert_secret_name" {
  type    = string
  default = "besu-node-ca-cert"
}

# --- IRSA role ARNs (from modules/iam) ---------------------------------------
variable "genesis_role_arn" {
  description = "Write-capable IRSA role ARN for the genesis Job (besu_genesis_role_arn)."
  type        = string
}

variable "pod_role_arn" {
  description = "Read-only IRSA role ARN for Besu node pods (besu_secrets_role_arn)."
  type        = string
}

# --- Permissioning -----------------------------------------------------------
variable "node_permissioning_mode" {
  type    = string
  default = "local"
}

variable "account_permissioning_mode" {
  type    = string
  default = "off" # off | local (file-based accounts-allowlist, C6). The on-chain contract path was removed — C8/F17.
}

# C6: name of the shared ConfigMap holding the file-based account allowlist. The
# genesis chart creates it (seeded from admin + initial_account_allowlist) and every
# besu-node mounts it — one name keeps the two charts in agreement (no hardcoding).
variable "account_allowlist_configmap_name" {
  type    = string
  default = "besu-account-allowlist"
}

variable "permissioning_admin_account" {
  type    = string
  default = ""
}


variable "initial_account_allowlist" {
  type    = list(string)
  default = []
}

# F20: addresses to alloc a genesis BALANCE (decoupled from permissioning). Needed
# on a zero-gas chain so a tx originator can submit transactions even with account
# permissioning OFF.
variable "genesis_funded_accounts" {
  type    = list(string)
  default = []
}

# C4: when true, the genesis Job builds QBFT extraData from the operator-supplied
# validator keys (in Secrets Manager) instead of freshly-generated ones.
variable "use_provided_validator_keys" {
  type    = bool
  default = false
}

# H11: QBFT 25<->26 wire-compat flag (--Xbft-legacy-protocol-encoding). Default false
# (fresh 26.x deploys don't need it); the rolling upgrade script sets it via --set for a
# mixed-version window, then clears it once every node is on 26.x.
variable "bft_legacy_protocol_encoding" {
  description = "Append --Xbft-legacy-protocol-encoding for a 25<->26 mixed-version rolling upgrade. Keep false for fresh single-version deploys."
  type        = bool
  default     = false
}

# H23: RPC listener DNS-rebinding + CORS scoping (were hardcoded "*").
variable "rpc_host_allowlist" {
  description = "Value for Besu --host-allowlist on every RPC listener (DNS-rebinding protection). Default \"*\"; scope to the RPC SAN / service DNS at go-live."
  type        = string
  default     = "*"
}

variable "rpc_cors_origins" {
  description = "Value for Besu --rpc-http-cors-origins on every RPC listener. Default \"none\" — all pools are server-to-server or mTLS; the browser never calls Besu directly."
  type        = string
  default     = "none"
}

# H2: re-genesis guard. false (default) => the genesis Job refuses to overwrite an
# existing besu-genesis ConfigMap, protecting a live chain from a genesis-hash brick
# (a re-run republishes genesis.json built from freshly-generated identities that no
# longer match the validators' RocksDB). Set true ONLY for a deliberate, destructive
# re-genesis, AFTER wiping the node-key secrets + validator PVCs. Paired with the
# helm_release.genesis lifecycle{ ignore_changes=[values] } guard (main.tf) and the
# Job's own ConfigMap-exists check. See docs/production-hardening-backlog.md H2.
variable "allow_regenesis" {
  type    = bool
  default = false
}

# --- Storage -----------------------------------------------------------------
variable "storage_class_name" {
  type    = string
  default = "besu-gp3"
}

variable "data_volume_size_gib" {
  type    = number
  default = 100
}

# --- Ports / DNS -------------------------------------------------------------
variable "cluster_domain" {
  type    = string
  default = "cluster.local"
}

variable "p2p_port" {
  type    = number
  default = 30303
}

variable "rpc_http_port" {
  type    = number
  default = 8545
}

variable "metrics_port" {
  type    = number
  default = 9545
}

variable "rpc_ws_port" {
  description = "WebSocket RPC port for the app-rpc pool (eth_subscribe)."
  type        = number
  default     = 8546
}

# --- Stage 4: RPC mTLS edge --------------------------------------------------
variable "rpc_mtls_enabled" {
  description = "Enable native Besu mTLS on the RPC nodes (keystore/truststore must be issued into Secrets Manager first)."
  type        = bool
  default     = false
}

variable "rpc_auth_mode" {
  description = "RPC auth mode: 'tls-only' or 'tls-plus-method' (JWT method scoping)."
  type        = string
  default     = "tls-plus-method"
}

variable "rpc_target_group_arn" {
  description = "ARN of the internal NLB target group (modules/rpc-access). When set (and deploy), the besu-rpc-edge release binds the RPC pods to it. Empty disables the binding."
  type        = string
  default     = ""
}

# --- Stage 8: app-rpc pool (server-TLS + JWT, HTTP+WS) -----------------------
variable "app_rpc_tls_enabled" {
  description = "Enable server-side TLS (https/wss) on the app-rpc pool (CA-signed server keystore; no client auth)."
  type        = bool
  default     = true
}

variable "app_rpc_ws_enabled" {
  description = "Expose the WS plane on the app-rpc pool (eth_subscribe for the event listener)."
  type        = bool
  default     = true
}

variable "app_rpc_auth_enabled" {
  description = "Require JWT auth on the app-rpc pool (the app mints tokens; Besu verifies with the pubkey)."
  type        = bool
  default     = true
}

variable "app_rpc_keystore_secret_name" {
  description = "Secrets Manager name of the app-rpc base64 PKCS12 server keystore."
  type        = string
  default     = "besu-node-apprpc-keystore"
}

variable "app_rpc_keystore_password_secret_name" {
  description = "Secrets Manager name of the app-rpc keystore password."
  type        = string
  default     = "besu-node-apprpc-keystore-password"
}

variable "app_rpc_jwt_pubkey_secret_name" {
  description = "Secrets Manager name of the app-rpc JWT verification public key (PEM)."
  type        = string
  default     = "besu-node-apprpc-jwt-pubkey"
}

variable "app_rpc_target_group_arns" {
  description = "Stage 8: app-rpc NLB target group ARNs by port name (http/ws) from modules/rpc-access. When set (and deploy), besu-rpc-edge binds the app-rpc pods to them."
  type        = map(string)
  default     = {}
}

# --- Stage 8: validator-internal ops listener --------------------------------
variable "ops_rpc_enabled" {
  description = "Enable the validator-internal ops RPC listener (QBFT/admin via kubectl port-forward; never NLB-fronted)."
  type        = bool
  default     = false
}

variable "ops_rpc_jwt_pubkey_secret_name" {
  description = "Optional JWT pubkey secret for the ops listener. Empty = no auth (internal-only path)."
  type        = string
  default     = ""
}

# H6: escape hatch for the ops-listener JWT precondition. When ops_rpc_enabled=true
# and no JWT pubkey is set, the chart FAILS render unless this is true (accepting the
# ClusterIP + port-forward + NetworkPolicy trust model without a JWT).
variable "ops_rpc_allow_no_jwt" {
  description = "Allow the ops listener to run without a JWT pubkey (ClusterIP+port-forward-only trust). Keep false and set a JWT for prod."
  type        = bool
  default     = false
}

# H6: NetworkPolicy config for the besu-node pods. Default disabled — it only
# ENFORCES when the VPC CNI NetworkPolicy agent is enabled, and the client sources
# must be set per deployment (an incomplete set denies legitimate RPC). Validate on
# a mock deploy before relying on it.
variable "network_policy" {
  description = "Per-role NetworkPolicy ingress lockdown (H6). Disabled by default; set client sources + enable the VPC CNI NetworkPolicy agent to enforce."
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
# D-39 — one validator per node, as a hard scheduling constraint.
# -----------------------------------------------------------------------------
# Rendered as required podAntiAffinity on kubernetes.io/hostname for role=validator.
# NOT a topologySpreadConstraint: maxSkew=1 on hostname permits a 2/1/1 placement
# across three nodes, so no tuning of a spread constraint can express "never two
# on one node".
#
# Why it is a decision rather than a default: two validators on one node means a
# single node drain removes 2 of 4 and the chain HALTS (H1) — and the co-location
# is SILENT. Four Running pods on three nodes is indistinguishable from four on
# four. Under CT-5 the node count is the cloud team's (#28), so we can no longer
# make the co-location impossible by sizing.
#
# Leaving it true can leave the fourth validator Pending when fewer than four
# nodes are schedulable. That is the intended failure: Pending is loud and shows
# up before go-live, co-location is discovered during an incident.
variable "validator_require_distinct_nodes" {
  description = "D-39: require each validator on a distinct node (required podAntiAffinity on hostname). Setting false permits two validators per node, which makes a single drain a chain halt with no prior signal."
  type        = bool
  default     = true
}
