# =============================================================================
# modules/blockscout/variables.tf — Stage 9 Blockscout explorer (in-cluster).
# =============================================================================
variable "deploy" {
  description = "Create the Blockscout Helm release. Gated by enable_blockscout AND deploy_in_cluster_resources at the root (needs the private EKS endpoint)."
  type        = bool
  default     = false
}

variable "namespace" {
  type    = string
  default = "besu"
}

variable "chart_dir" {
  description = "Path to helm/charts (so the module can reference the besu-blockscout chart)."
  type        = string
}

# --- Chain / RPC (from modules/besu explorer-rpc outputs) --------------------
variable "chain_id" { type = number }
variable "network_name" {
  type    = string
  default = "Besu (private)"
}
variable "subnetwork" {
  type    = string
  default = ""
}
variable "rpc_http_url" {
  description = "In-cluster explorer-rpc HTTP URL (eth + debug/trace)."
  type        = string
}
variable "rpc_ws_url" {
  description = "In-cluster explorer-rpc WS URL (eth_subscribe). Empty disables WS in Blockscout."
  type        = string
  default     = ""
}

# --- Images (PIN; verify tags at deploy — CLAUDE.md §6) ----------------------
variable "blockscout_image" {
  description = "Backend image (indexer + API; no embedded UI in v6+). ghcr.io tag — NOT the GitHub repo release tag; Docker Hub is stale. 9.0.2 verified 2026-06-26."
  type        = string
  default     = "ghcr.io/blockscout/blockscout:9.0.2"
}
variable "frontend_image" {
  description = "Frontend image (the Next.js UI; separate version track). ghcr.io tag (tops out at v2.3.x). v2.3.5 verified 2026-06-26."
  type        = string
  default     = "ghcr.io/blockscout/frontend:v2.3.5"
}
variable "postgres_image" {
  type    = string
  default = "postgres:16-alpine"
}

# The stats, visualizer and proxy images were NOT parameterised: they came from
# the chart's values.yaml, hardcoded to ghcr.io and docker.io. In a VPC with no
# egress those three pods would hang on ImagePullBackOff with nothing naming the
# registry, while every other component pulled fine from the mirror.
variable "stats_image" {
  description = "Stats microservice image. ghcr.io tag; v2.16.0 verified 2026-06-26."
  type        = string
  default     = "ghcr.io/blockscout/stats:v2.16.0"
}

variable "visualizer_image" {
  description = "Visualizer microservice image. ghcr.io tag; v0.2.1 verified 2026-06-26."
  type        = string
  default     = "ghcr.io/blockscout/visualizer:v0.2.1"
}

variable "proxy_image" {
  description = "nginx image fronting the Blockscout UI and API."
  type        = string
  default     = "nginx:1.27-alpine"
}

# --- UI access (the browser-facing origin = the port-forward to the proxy) ----
variable "access_host" {
  description = "host:port the browser uses (local end of the port-forward to the proxy). NEXT_PUBLIC_API_HOST/APP_HOST bake from this."
  type        = string
  default     = "localhost:4000"
}
variable "access_protocol" {
  type    = string
  default = "http"
}

# --- PostgreSQL sizing (mirror rule: same component both envs, size differs) --
variable "storage_class_name" {
  type    = string
  default = "besu-gp3"
}
variable "pg_storage_size_gib" {
  type    = number
  default = 10
}
