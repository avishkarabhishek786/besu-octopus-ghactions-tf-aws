# =============================================================================
# modules/runner/main.tf
# -----------------------------------------------------------------------------
# PURPOSE
#   The In-VPC EC2 Runner. A laptop outside the VPC can call AWS APIs but CANNOT
#   reach the cluster's PRIVATE Kubernetes API endpoint, so any in-cluster
#   resource (Helm releases, the Besu charts, the StorageClass, manifests) must
#   be applied from INSIDE the VPC. This module provisions a minimal EC2 host in
#   a private subnet that satisfies "nothing public":
#     * No public IP, no SSH key — access is ONLY via SSM Session Manager
#       (outbound 443 to the SSM endpoints over NAT).
#     * IMDSv2 required (blocks SSRF credential theft).
#     * Instance role: SSM core + a deploy policy (terraform apply) + an EKS
#       ACCESS ENTRY granting Kubernetes admin so helm/kubectl work.
#     * Attached to the EKS-managed cluster security group so it is inside the
#       group permitted to reach the private API on 443.
#
# HOW AN OPERATOR USES IT
#   aws ssm start-session --target <instance-id>
#   # then on the runner:
#   aws eks update-kubeconfig --name <cluster> --region <region>
#   cd <repo>/terraform && terraform apply \
#     -var-file=environments/non-prod/main.tfvars \
#     -var deploy_in_cluster_resources=true
#
# LIFECYCLE / COST NOTE
#   Its own root (terraform/runner, C1): apply it after the chain's AWS layer,
#   tear it down with the stack. A t3.small is ~$0.02/hr. Once it carries a
#   registered Octopus Tentacle (CD-57), STOP it between deployments rather than
#   destroying it (CD-61): a recreated instance has a new certificate and a dead
#   registration, while a stopped one keeps its root volume, its identity and —
#   with var.private_ip — its allowlisted address, for the price of the EBS.
# =============================================================================

data "aws_partition" "current" {}

# Latest Amazon Linux 2023 AMI (SSM agent preinstalled) for x86_64.
data "aws_ssm_parameter" "al2023" {
  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64"
}

# -----------------------------------------------------------------------------
# INSTANCE IAM ROLE  (SSM + deploy permissions)
# -----------------------------------------------------------------------------
data "aws_iam_policy_document" "assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "runner" {
  name               = "${var.name_prefix}-runner-role"
  assume_role_policy = data.aws_iam_policy_document.assume.json
  tags               = merge(var.tags, { Component = "runner" })
}

# SSM Session Manager connectivity (no SSH needed).
resource "aws_iam_role_policy_attachment" "ssm" {
  role       = aws_iam_role.runner.name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

# Permissions to run `terraform apply` for this stack (broad in non-prod; scope
# down in prod via var.deploy_policy_arn).
resource "aws_iam_role_policy_attachment" "deploy" {
  role       = aws_iam_role.runner.name
  policy_arn = var.deploy_policy_arn
}

# D-21: read the toolchain + source bundle. Scoped to THIS bucket and nothing
# else — the runner already holds a broad deploy policy (H5), so every additional
# grant is written narrowly rather than folded into it.
data "aws_iam_policy_document" "artifacts_read" {
  statement {
    effect    = "Allow"
    actions   = ["s3:GetObject", "s3:GetObjectVersion"]
    resources = ["${var.artifacts_bucket_arn}/*"]
  }
  statement {
    effect    = "Allow"
    actions   = ["s3:ListBucket"]
    resources = [var.artifacts_bucket_arn]
  }
}

resource "aws_iam_role_policy" "artifacts_read" {
  name   = "${var.name_prefix}-runner-artifacts-read"
  role   = aws_iam_role.runner.id
  policy = data.aws_iam_policy_document.artifacts_read.json
}

resource "aws_iam_instance_profile" "runner" {
  name = "${var.name_prefix}-runner-profile"
  role = aws_iam_role.runner.name
  tags = merge(var.tags, { Component = "runner" })
}

# -----------------------------------------------------------------------------
# EKS ACCESS ENTRY  (Kubernetes RBAC for the runner role)
# -----------------------------------------------------------------------------
# An IAM principal needs an EKS access entry to have Kubernetes permissions
# (the modern replacement for the aws-auth ConfigMap). We grant the runner role
# cluster-admin so helm/kubectl can install the Besu charts. (Scope to a
# narrower policy in prod if you split deploy duties.)
resource "aws_eks_access_entry" "runner" {
  cluster_name  = var.cluster_name
  principal_arn = aws_iam_role.runner.arn
  type          = "STANDARD"
  tags          = merge(var.tags, { Component = "runner" })
}

resource "aws_eks_access_policy_association" "runner_admin" {
  cluster_name  = var.cluster_name
  principal_arn = aws_iam_role.runner.arn
  policy_arn    = "arn:${data.aws_partition.current.partition}:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"

  access_scope {
    type = "cluster"
  }

  depends_on = [aws_eks_access_entry.runner]
}

# -----------------------------------------------------------------------------
# SECURITY GROUP  (egress only)
# -----------------------------------------------------------------------------
# The runner needs outbound to: the SSM interface endpoints, the other AWS API
# endpoints, the EKS API (443), and the S3 GATEWAY endpoint for its toolchain and
# source bundle. It needs NO internet — D-21 removed every download. No inbound is
# required either; SSM is initiated outbound by the agent.
resource "aws_security_group" "runner" {
  name        = "${var.name_prefix}-runner-sg"
  description = "In-VPC runner: egress only; SSM-managed, no inbound"
  vpc_id      = var.vpc_id

  egress {
    description = "All outbound (SSM + AWS API endpoints, EKS API, S3 gateway endpoint). Resolves to VPC endpoints only: no route to the internet."
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(var.tags, {
    Name      = "${var.name_prefix}-runner-sg"
    Component = "runner"
  })
}

# -----------------------------------------------------------------------------
# THE RUNNER INSTANCE
# -----------------------------------------------------------------------------
# The subnet, read back so a pinned address can be checked against it at plan
# time. Terraform has no cidrcontains() (build finding B1); membership is
# "normalise the IP to the subnet's prefix length and compare": an address is in
# 10.60.0.0/24 iff cidrsubnet("<ip>/24", 0, 0) == "10.60.0.0/24".
data "aws_subnet" "runner" {
  id = var.subnet_id
}

locals {
  runner_ip_in_subnet = var.private_ip == null ? true : (
    cidrsubnet("${var.private_ip}/${split("/", data.aws_subnet.runner.cidr_block)[1]}", 0, 0) == data.aws_subnet.runner.cidr_block
  )
}

resource "aws_instance" "runner" {
  ami                  = data.aws_ssm_parameter.al2023.value
  instance_type        = var.instance_type
  subnet_id            = var.subnet_id
  iam_instance_profile = aws_iam_instance_profile.runner.name

  # CD-60: the allowlisted /32, when the egress proxy needs one. null = AWS picks.
  private_ip = var.private_ip

  lifecycle {
    precondition {
      condition     = local.runner_ip_in_subnet
      error_message = "private_ip ${coalesce(var.private_ip, "n/a")} is not inside subnet ${var.subnet_id} (${data.aws_subnet.runner.cidr_block}). The egress allowlist source must be an address IN the runner's subnet (CD-60)."
    }
  }

  # No public IP — private subnet only, SSM access.
  associate_public_ip_address = false

  # Runner SG (egress) + the EKS-managed cluster SG so it can reach the private
  # API endpoint on 443 (intra-group traffic is allowed by that SG).
  vpc_security_group_ids = [
    aws_security_group.runner.id,
    var.cluster_primary_security_group_id,
  ]

  # IMDSv2 required.
  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 2
  }

  root_block_device {
    volume_size = 20
    volume_type = "gp3"
    encrypted   = true
  }

  # ---------------------------------------------------------------------------
  # BOOTSTRAP — zero internet, zero package installs (D-21)
  # ---------------------------------------------------------------------------
  # This VPC has NO egress. The previous bootstrap reached five internet hosts
  # (dnf repos, dl.k8s.io, raw.githubusercontent.com, rpm.releases.hashicorp.com,
  # awscli.amazonaws.com) and then `git clone`d GitHub. In the real VPC each of
  # those HANGS until timeout rather than failing — and since this instance is the
  # only path to the private EKS API, a hung bootstrap blocks the whole deployment
  # with no useful signal.
  #
  # Everything now arrives as two S3 objects over the GATEWAY endpoint (free, and
  # already required for ECR image layers). The only tools this script itself
  # needs are `aws`, `tar` and `gzip` — all three ship in the AL2023 base AMI, so
  # there is nothing to install before we can install anything.
  #
  # Archives are unpacked on the LAPTOP by push-runner-bundle.sh, so the runner
  # needs no `unzip` either. See scripts/runner/push-runner-bundle.sh.
  user_data = <<-EOF
    #!/bin/bash
    set -euxo pipefail

    BUNDLE_S3="s3://${var.artifacts_bucket}"
    TOOLS_DIR=/usr/local/besu-tools
    STATUS_FILE=/opt/besu-deploy/BOOTSTRAP_STATUS
    mkdir -p /opt/besu-deploy "$TOOLS_DIR"

    # A failed bootstrap must fail LOUDLY (the F28 lesson: a runner that looks
    # healthy with an empty /opt/besu-deploy costs an afternoon). Every fatal path
    # writes the status marker, prints the fix, and exits non-zero so
    # `cloud-init status` reports error and the runner root's
    # `runner_bootstrap_check` output catches it immediately.
    fatal() {
      echo "FAILED: $1" > "$STATUS_FILE"
      echo "[bootstrap] FATAL: $1"
      echo "[bootstrap] fix, then RECREATE the runner:"
      echo "[bootstrap]   terraform apply -replace=module.runner.aws_instance.runner"
      exit 1
    }

    # --- toolchain -----------------------------------------------------------
    # kubectl / helm / terraform / a Corretto JRE (keytool, needed by
    # scripts/pki/issue-server-cert.sh — an openssl-built PKCS12 truststore makes
    # Besu throw a TLS internal error during client-cert validation).
    aws s3 cp "$BUNDLE_S3/tools/tools.tar.gz" /tmp/tools.tar.gz --region "${var.region}" \
      || fatal "could not fetch tools.tar.gz from $BUNDLE_S3 (run scripts/runner/push-runner-bundle.sh from the laptop, then recreate this instance)"
    tar xzf /tmp/tools.tar.gz -C "$TOOLS_DIR" || fatal "tools.tar.gz is corrupt"
    rm -f /tmp/tools.tar.gz

    # PATH for interactive SSM sessions AND for scripts run from them.
    cat > /etc/profile.d/besu-tools.sh <<'PROFILE'
    export JAVA_HOME=/usr/local/besu-tools/jvm
    export PATH="/usr/local/besu-tools/bin:$JAVA_HOME/bin:$PATH"
    # D-20: providers from the bundle's filesystem mirror, never the registry.
    [ -f /usr/local/besu-tools/terraformrc ] && export TF_CLI_CONFIG_FILE=/usr/local/besu-tools/terraformrc
    PROFILE
    chmod 0644 /etc/profile.d/besu-tools.sh
    export JAVA_HOME="$TOOLS_DIR/jvm"
    export PATH="$TOOLS_DIR/bin:$JAVA_HOME/bin:$PATH"

    for t in kubectl helm terraform keytool; do
      command -v "$t" >/dev/null 2>&1 || fatal "$t missing after unpacking the bundle — rebuild it with push-runner-bundle.sh"
    done

    # --- source --------------------------------------------------------------
    # `git archive` output: the committed tree, no .git, no gitignored files.
    SRC=/opt/besu-deploy/sbsa_besu
    mkdir -p "$SRC"
    aws s3 cp "$BUNDLE_S3/source/source.tar.gz" /tmp/source.tar.gz --region "${var.region}" \
      || fatal "could not fetch source.tar.gz from $BUNDLE_S3 (push it with scripts/runner/push-runner-bundle.sh)"
    tar xzf /tmp/source.tar.gz -C "$SRC" || fatal "source.tar.gz is corrupt"
    rm -f /tmp/source.tar.gz
    SRC_REF="$(aws s3api head-object --bucket "${var.artifacts_bucket}" --key source/source.tar.gz \
      --region "${var.region}" --query 'Metadata."git-ref"' --output text 2>/dev/null || echo unknown)"

    # --- gitignored env config ----------------------------------------------
    # SOFT-fails by design: the operator may push the config AFTER the runner is
    # up, then re-run fetch-deploy-config.sh over SSM.
    CFG=extracted
    if [ -n "${var.deploy_config_secret_name}" ] && [ -f "$SRC/scripts/runner/fetch-deploy-config.sh" ]; then
      DEPLOY_CONFIG_SECRET="${var.deploy_config_secret_name}" AWS_REGION="${var.region}" \
        bash "$SRC/scripts/runner/fetch-deploy-config.sh" \
        || CFG="NOT extracted (run push-deploy-config.sh from the laptop, then fetch-deploy-config.sh here)"
    else
      CFG="skipped (no deploy_config_secret_name)"
    fi

    echo "OK: tools=$(cat $TOOLS_DIR/MANIFEST.txt 2>/dev/null | grep -c $'\t' || echo '?') source=$SRC_REF deploy-config: $CFG" > "$STATUS_FILE"
    echo "[bootstrap] ready. source=$SRC_REF"
  EOF

  tags = merge(var.tags, {
    Name      = "${var.name_prefix}-runner"
    Component = "runner"
  })
}
