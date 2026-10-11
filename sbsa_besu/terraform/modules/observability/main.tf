# =============================================================================
# modules/observability/main.tf
# -----------------------------------------------------------------------------
# PURPOSE — the monitoring/alerting/audit plane (settled design):
#   * Prometheus + Grafana + Alertmanager (kube-prometheus-stack).
#   * Alertmanager -> SNS -> email (infra/app alerts to the on-call inbox).
#   * Fluent Bit -> CloudWatch Logs (pod logs centralised + retained).
#   * Native CloudWatch alarm(s) -> SNS (infra signal independent of the chain).
#   * CloudTrail -> S3 (API audit trail for the account).
# Trimmed to coexist with Besu on the 2-node non-prod cluster.
# =============================================================================

data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}

locals {
  fluentbit_log_group = "/aws/besu/${var.cluster_name}/pods"
  # Derive the CloudWatch dimension suffixes from the ARNs (net/<name>/<id>,
  # targetgroup/<name>/<id>); only build the NLB alarm when both are provided.
  nlb_suffix = var.rpc_nlb_arn != "" ? regex(".*:loadbalancer/(.*)$", var.rpc_nlb_arn)[0] : ""
  tg_suffix  = var.rpc_target_group_arn != "" ? regex(".*:(targetgroup/.*)$", var.rpc_target_group_arn)[0] : ""
}

# -----------------------------------------------------------------------------
# SNS ALERTS TOPIC (+ email subscription)
# -----------------------------------------------------------------------------
resource "aws_sns_topic" "alerts" {
  name = "${var.name_prefix}-alerts"
  tags = merge(var.tags, { Component = "observability" })
}

resource "aws_sns_topic_subscription" "email" {
  count = var.alert_email == "" ? 0 : 1

  topic_arn = aws_sns_topic.alerts.arn
  protocol  = "email"
  endpoint  = var.alert_email
}

# Allow CloudWatch alarms to publish to the topic.
resource "aws_sns_topic_policy" "alerts" {
  arn = aws_sns_topic.alerts.arn
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "AllowCloudWatchAlarms"
      Effect    = "Allow"
      Principal = { Service = "cloudwatch.amazonaws.com" }
      Action    = "sns:Publish"
      Resource  = aws_sns_topic.alerts.arn
    }]
  })
}

# -----------------------------------------------------------------------------
# FLUENT BIT — log group + IRSA (pod logs -> CloudWatch)
# -----------------------------------------------------------------------------
resource "aws_cloudwatch_log_group" "pods" {
  name              = local.fluentbit_log_group
  retention_in_days = var.log_retention_days
  tags              = merge(var.tags, { Component = "observability" })
}

data "aws_iam_policy_document" "fluentbit_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = [var.oidc_provider_arn]
    }
    condition {
      test     = "StringEquals"
      variable = "${var.oidc_provider_url}:sub"
      values   = ["system:serviceaccount:kube-system:aws-for-fluent-bit"]
    }
    condition {
      test     = "StringEquals"
      variable = "${var.oidc_provider_url}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "fluentbit" {
  name                 = "${var.name_prefix}-fluentbit-irsa"
  assume_role_policy   = data.aws_iam_policy_document.fluentbit_assume.json
  permissions_boundary = var.permissions_boundary # H5: cap — no IAM/org/account mutation
  tags                 = merge(var.tags, { Component = "observability" })
}

resource "aws_iam_role_policy" "fluentbit" {
  name = "fluentbit-cwlogs"
  role = aws_iam_role.fluentbit.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents",
        "logs:DescribeLogGroups", "logs:DescribeLogStreams", "logs:PutRetentionPolicy",
      ]
      Resource = "${aws_cloudwatch_log_group.pods.arn}:*"
    }]
  })
}

# -----------------------------------------------------------------------------
# ALERTMANAGER IRSA (sns:Publish to the alerts topic)
# -----------------------------------------------------------------------------
data "aws_iam_policy_document" "alertmanager_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = [var.oidc_provider_arn]
    }
    condition {
      test     = "StringEquals"
      variable = "${var.oidc_provider_url}:sub"
      values   = ["system:serviceaccount:${var.monitoring_namespace}:besu-alertmanager"]
    }
    condition {
      test     = "StringEquals"
      variable = "${var.oidc_provider_url}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "alertmanager" {
  name                 = "${var.name_prefix}-alertmanager-irsa"
  assume_role_policy   = data.aws_iam_policy_document.alertmanager_assume.json
  permissions_boundary = var.permissions_boundary # H5: cap — no IAM/org/account mutation
  tags                 = merge(var.tags, { Component = "observability" })
}

resource "aws_iam_role_policy" "alertmanager" {
  name = "alertmanager-sns"
  role = aws_iam_role.alertmanager.id
  policy = jsonencode({
    Version   = "2012-10-17"
    Statement = [{ Effect = "Allow", Action = "sns:Publish", Resource = aws_sns_topic.alerts.arn }]
  })
}

# -----------------------------------------------------------------------------
# CLOUDWATCH ALARM — RPC NLB unhealthy targets -> SNS (infra signal)
# -----------------------------------------------------------------------------
resource "aws_cloudwatch_metric_alarm" "rpc_unhealthy" {
  count = var.enable_nlb_alarm ? 1 : 0

  alarm_name          = "${var.name_prefix}-rpc-unhealthy-targets"
  alarm_description   = "RPC NLB has unhealthy targets (RPC availability at risk)."
  namespace           = "AWS/NetworkELB"
  metric_name         = "UnHealthyHostCount"
  statistic           = "Maximum"
  period              = 60
  evaluation_periods  = 3
  threshold           = 1
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching"

  dimensions = {
    LoadBalancer = local.nlb_suffix
    TargetGroup  = local.tg_suffix
  }

  alarm_actions = [aws_sns_topic.alerts.arn]
  ok_actions    = [aws_sns_topic.alerts.arn]
  tags          = merge(var.tags, { Component = "observability" })
}

# -----------------------------------------------------------------------------
# CLOUDTRAIL (+ S3 bucket) — account API audit
# -----------------------------------------------------------------------------
resource "aws_s3_bucket" "trail" {
  count  = var.enable_cloudtrail ? 1 : 0
  bucket = "${var.name_prefix}-cloudtrail-${data.aws_caller_identity.current.account_id}"
  # H19: gate force_destroy. true (deploy-test) allows clean teardown of a non-empty
  # bucket; false (prod) makes `terraform destroy` REFUSE to wipe the forensic record.
  force_destroy = var.cloudtrail_force_destroy
  tags          = merge(var.tags, { Component = "observability" })
}

# H19: versioning — keeps prior object versions so a delete/overwrite of a trail log
# is recoverable (tamper-evidence beyond CloudTrail's own log-file validation).
resource "aws_s3_bucket_versioning" "trail" {
  count  = var.enable_cloudtrail ? 1 : 0
  bucket = aws_s3_bucket.trail[0].id
  versioning_configuration {
    status = "Enabled"
  }
}

# H19: server-side encryption. SSE-KMS with a customer CMK when provided (per-object
# KMS audit + controlled key policy), else SSE-S3 (AES256) as a baseline. A CMK here
# must allow CloudTrail (delivery.logs) to GenerateDataKey/Decrypt.
resource "aws_s3_bucket_server_side_encryption_configuration" "trail" {
  count  = var.enable_cloudtrail ? 1 : 0
  bucket = aws_s3_bucket.trail[0].id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = var.cloudtrail_kms_key_arn != "" ? "aws:kms" : "AES256"
      kms_master_key_id = var.cloudtrail_kms_key_arn != "" ? var.cloudtrail_kms_key_arn : null
    }
    bucket_key_enabled = var.cloudtrail_kms_key_arn != "" ? true : null
  }
}

resource "aws_s3_bucket_public_access_block" "trail" {
  count                   = var.enable_cloudtrail ? 1 : 0
  bucket                  = aws_s3_bucket.trail[0].id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_policy" "trail" {
  count  = var.enable_cloudtrail ? 1 : 0
  bucket = aws_s3_bucket.trail[0].id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "AWSCloudTrailAclCheck"
        Effect    = "Allow"
        Principal = { Service = "cloudtrail.amazonaws.com" }
        Action    = "s3:GetBucketAcl"
        Resource  = aws_s3_bucket.trail[0].arn
      },
      {
        Sid       = "AWSCloudTrailWrite"
        Effect    = "Allow"
        Principal = { Service = "cloudtrail.amazonaws.com" }
        Action    = "s3:PutObject"
        Resource  = "${aws_s3_bucket.trail[0].arn}/AWSLogs/${data.aws_caller_identity.current.account_id}/*"
        Condition = { StringEquals = { "s3:x-amz-acl" = "bucket-owner-full-control" } }
      },
    ]
  })
}

resource "aws_cloudtrail" "this" {
  count = var.enable_cloudtrail ? 1 : 0

  name                          = "${var.name_prefix}-trail"
  s3_bucket_name                = aws_s3_bucket.trail[0].id
  include_global_service_events = true
  is_multi_region_trail         = true
  enable_log_file_validation    = true
  # H19: encrypt the delivered trail logs with a customer CMK when provided.
  kms_key_id = var.cloudtrail_kms_key_arn != "" ? var.cloudtrail_kms_key_arn : null
  tags       = merge(var.tags, { Component = "observability" })

  # C12 audit: KMS cryptographic operations on the node-key CMK — Decrypt (pod
  # start / CSI), GenerateDataKey (genesis write) — are CloudTrail **management**
  # events, captured by this trail's default management-event logging. They are
  # NOT "data events": AWS::KMS::Key is not a valid data-event resource.type
  # (PutEventSelectors rejects it), so no advanced_event_selector is used. The
  # per-decrypt audit the FIPS Option-B controls promise is therefore satisfied by
  # this base trail as-is (each Decrypt appears under eventSource kms.amazonaws.com).
  # (enable_kms_data_events / node_key_cmk_arn are retained as inputs but no longer
  # drive a selector — see docs/fips-140-l3-validator-key-management-analysis.md §11.)

  depends_on = [aws_s3_bucket_policy.trail]
}

# =============================================================================
# IN-CLUSTER (gated) — kube-prometheus-stack + aws-for-fluent-bit
# =============================================================================
locals {
  # PORTING item 4: Helm value path -> chart_images key. Rendered as one string
  # `set` per attribute, and only for keys present, so an absent key keeps the
  # chart's own default rather than nulling it.
  kps_image_sets_paths = {
    "prometheusOperator.image"                          = "prometheus-operator"
    "prometheusOperator.prometheusConfigReloader.image" = "config-reloader"
    "prometheusOperator.admissionWebhooks.patch.image"  = "kube-webhook-certgen"
    "prometheus.prometheusSpec.image"                   = "prometheus"
    "alertmanager.alertmanagerSpec.image"               = "alertmanager"
    "prometheus-node-exporter.image"                    = "node-exporter"
    "kube-state-metrics.image"                          = "kube-state-metrics"
    "grafana.image"                                     = "grafana"
    "grafana.sidecar.image"                             = "k8s-sidecar"
  }
  kps_image_sets = merge([for path, key in local.kps_image_sets_paths :
    { for attr, val in { registry = var.chart_images[key].registry, repository = var.chart_images[key].repository, tag = var.chart_images[key].tag } : "${path}.${attr}" => val }
    if contains(keys(var.chart_images), key)
  ]...)

  # node-exporter: the parent chart sets image.distroless=true, and the subchart
  # APPENDS "-distroless" to whatever tag it is given -- so the mirror's
  # "v1.11.1-distroless" would be pulled as "v1.11.1-distroless-distroless". When
  # we name the tag, it is the exact tag pulled: turn the suffix off. A real
  # boolean, so a values entry rather than a `set` (whose type is "string").
  kps_extra_values = { for k in(contains(keys(var.chart_images), "node-exporter") ? ["prometheus-node-exporter"] : []) :
    k => { image = { distroless = false } }
  }

  # PORTING item 4: Helm value path -> chart_images key. Rendered as one string
  # `set` per attribute, and only for keys present, so an absent key keeps the
  # chart's own default rather than nulling it.
  fluentbit_image_sets_paths = {
    "image" = "fluent-bit"
  }
  fluentbit_image_sets = merge([for path, key in local.fluentbit_image_sets_paths :
    { for attr, val in { repository = "${var.chart_images[key].registry}/${var.chart_images[key].repository}", tag = var.chart_images[key].tag } : "${path}.${attr}" => val }
    if contains(keys(var.chart_images), key)
  ]...)
}

resource "helm_release" "kube_prometheus_stack" {
  count = var.deploy_in_cluster_resources ? 1 : 0

  name             = "kube-prometheus-stack"
  repository       = var.chart_repository != "" ? var.chart_repository : "https://prometheus-community.github.io/helm-charts"
  chart            = "kube-prometheus-stack"
  version          = var.kube_prometheus_chart_version
  namespace        = var.monitoring_namespace
  create_namespace = true
  timeout          = 900

  dynamic "set" {
    for_each = local.kps_image_sets
    content {
      name  = set.key
      value = set.value
      type  = "string"
    }
  }

  values = [local.kps_main_values, yamlencode(local.kps_extra_values)]
}

locals {
  kps_main_values = yamlencode({
    # EKS hides these control-plane components — disable their (always-down) monitors.
    kubeEtcd                 = { enabled = false }
    kubeControllerManager    = { enabled = false }
    kubeScheduler            = { enabled = false }
    kubeProxy                = { enabled = false }
    prometheus-node-exporter = { resources = { requests = { cpu = "20m", memory = "32Mi" } } }
    kube-state-metrics       = { resources = { requests = { cpu = "20m", memory = "64Mi" } } }

    grafana = {
      adminPassword  = var.grafana_admin_password
      persistence    = { enabled = false }
      resources      = { requests = { cpu = "100m", memory = "128Mi" }, limits = { memory = "256Mi" } }
      serviceMonitor = { enabled = true }
    }

    prometheus = {
      prometheusSpec = {
        retention = "2h" # short for the non-prod test (emptyDir, no PVC)
        resources = { requests = { cpu = "250m", memory = "700Mi" }, limits = { memory = "1500Mi" } }
        # Scrape Pod/Service/Rule objects from ALL namespaces (so besu-monitoring works).
        podMonitorSelectorNilUsesHelmValues     = false
        serviceMonitorSelectorNilUsesHelmValues = false
        ruleSelectorNilUsesHelmValues           = false
      }
    }

    alertmanager = {
      serviceAccount = {
        create      = true
        name        = "besu-alertmanager"
        annotations = { "eks.amazonaws.com/role-arn" = aws_iam_role.alertmanager.arn }
      }
      alertmanagerSpec = { resources = { requests = { cpu = "50m", memory = "64Mi" }, limits = { memory = "128Mi" } } }
      config = {
        route = {
          receiver        = "sns"
          group_wait      = "30s"
          group_interval  = "5m"
          repeat_interval = "3h"
        }
        receivers = [{
          name = "sns"
          sns_configs = [{
            topic_arn     = aws_sns_topic.alerts.arn
            sigv4         = { region = var.region }
            subject       = "Besu Alertmanager"
            send_resolved = true
          }]
        }]
      }
    }
  })
}

resource "helm_release" "fluentbit" {
  count = var.deploy_in_cluster_resources ? 1 : 0

  name       = "aws-for-fluent-bit"
  repository = var.chart_repository != "" ? var.chart_repository : "https://aws.github.io/eks-charts"
  chart      = "aws-for-fluent-bit"
  version    = var.fluentbit_chart_version
  namespace  = "kube-system"
  timeout    = 600

  dynamic "set" {
    for_each = local.fluentbit_image_sets
    content {
      name  = set.key
      value = set.value
      type  = "string"
    }
  }

  values = [yamlencode({
    serviceAccount = {
      create      = true
      name        = "aws-for-fluent-bit"
      annotations = { "eks.amazonaws.com/role-arn" = aws_iam_role.fluentbit.arn }
    }
    cloudWatchLogs = {
      enabled         = true
      region          = var.region
      logGroupName    = local.fluentbit_log_group
      autoCreateGroup = false # we pre-create with retention
      logStreamPrefix = "fb-"
    }
    firehose      = { enabled = false }
    kinesis       = { enabled = false }
    elasticsearch = { enabled = false }
    resources     = { requests = { cpu = "50m", memory = "64Mi" }, limits = { memory = "128Mi" } }
  })]

  depends_on = [aws_cloudwatch_log_group.pods]
}

# Besu PodMonitor + alert rules + Grafana dashboard. Applied after the stack so
# its CRDs (PodMonitor/PrometheusRule) exist.
resource "helm_release" "besu_monitoring" {
  count = var.deploy_in_cluster_resources ? 1 : 0

  name             = "besu-monitoring"
  chart            = "${path.module}/../../../helm/charts/besu-monitoring"
  namespace        = var.monitoring_namespace
  create_namespace = false
  timeout          = 300

  values = [yamlencode({
    besuNamespace       = var.besu_namespace
    monitoringNamespace = var.monitoring_namespace
    metricsPort         = "metrics"
  })]

  depends_on = [helm_release.kube_prometheus_stack]
}
