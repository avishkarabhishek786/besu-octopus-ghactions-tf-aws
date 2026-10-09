# =============================================================================
# modules/blockscout/main.tf — Stage 9 Blockscout explorer (in-cluster, private).
# -----------------------------------------------------------------------------
# Deploys the besu-blockscout chart (bundled Postgres + Blockscout backend) into
# the chain cluster. Indexes the dedicated explorer-rpc pool over ClusterIP
# (eth+debug/trace). Generates the DB password + Phoenix SECRET_KEY_BASE here so
# no secret is hard-coded or passed by the human. Fully private (no edge).
#
# In-cluster resource: applied from the In-VPC EC2 Runner (private EKS endpoint),
# like the Besu/observability releases. Gated by var.deploy.
# =============================================================================

# Postgres password (alphanumeric — avoids URL-encoding issues in DATABASE_URL).
resource "random_password" "db" {
  length  = 24
  special = false
}

# Phoenix SECRET_KEY_BASE — 64 chars, no special (avoids YAML/env quoting issues).
resource "random_password" "secret_key_base" {
  length  = 64
  special = false
}

resource "helm_release" "blockscout" {
  count = var.deploy ? 1 : 0

  name             = "besu-blockscout"
  chart            = "${var.chart_dir}/besu-blockscout"
  namespace        = var.namespace
  create_namespace = false
  wait             = false # indexing/migrations take time; verify with kubectl after
  timeout          = 600

  values = [yamlencode({
    namespace = var.namespace
    chain = {
      id          = var.chain_id
      rpcHttpUrl  = var.rpc_http_url
      rpcTraceUrl = var.rpc_http_url # Besu serves trace_/debug_ on the same listener
      rpcWsUrl    = var.rpc_ws_url
      networkName = var.network_name
      subnetwork  = var.subnetwork
    }
    blockscout = {
      image           = var.blockscout_image
      disableExternal = true
    }
    frontend = {
      image          = var.frontend_image
      accessHost     = var.access_host
      accessProtocol = var.access_protocol
      wsProtocol     = "ws"
    }
    stats = {
      image = var.stats_image
    }
    visualizer = {
      image = var.visualizer_image
    }
    proxy = {
      image = var.proxy_image
    }
    postgres = {
      image            = var.postgres_image
      storageClassName = var.storage_class_name
      storageSize      = "${var.pg_storage_size_gib}Gi"
    }
    secret = {
      name          = "blockscout-secrets"
      dbPassword    = random_password.db.result
      secretKeyBase = random_password.secret_key_base.result
    }
  })]
}
