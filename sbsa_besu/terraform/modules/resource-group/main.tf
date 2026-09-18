# =============================================================================
# modules/resource-group/main.tf
# -----------------------------------------------------------------------------
# PURPOSE
#   Creates an AWS Resource Group — the AWS equivalent of an Azure Resource
#   Group — that automatically collects every resource carrying this
#   deployment's tags. This gives you:
#     * A single console view ("Resource Groups") of everything in this
#       deployment, in this region.
#     * A programmatic handle the full-delete script uses as its PRIMARY
#       discovery mechanism (it queries the Resource Groups Tagging API for the
#       DeletionGroup tag).
#
# HOW IT WORKS
#   AWS Resource Groups are TAG-QUERY based. We define a group whose membership
#   query is "all resources where Project = <project> AND DeletionGroup =
#   <deletion_group>". Because every resource is tagged via the provider
#   default_tags, they all appear here automatically — no per-resource
#   registration needed.
#
# HONEST LIMITATIONS (documented so no one is misled)
#   * Resource Groups are REGION-SCOPED. Each region gets its own group; the
#     full-delete script must query both regions for a full footprint view.
#   * The Tagging API covers MOST but not ALL resource types. A few resources
#     (some EKS-managed sub-resources) may not appear. The full-delete script
#     therefore unions this group's results with Terraform state and targeted
#     API sweeps rather than trusting the group alone.
# =============================================================================

variable "name_prefix" {
  description = "Prefix for the resource group name."
  type        = string
}

variable "project_name" {
  description = "Project tag value to match."
  type        = string
}

variable "deletion_group" {
  description = "DeletionGroup tag value to match — the unique-per-deployment key."
  type        = string
}

variable "region_role" {
  description = "Either 'primary' or 'secondary' — included in the group name and description for clarity."
  type        = string
}

variable "tags" {
  description = "Tags applied to the resource group itself."
  type        = map(string)
  default     = {}
}

resource "aws_resourcegroups_group" "this" {
  name        = "${var.name_prefix}-${var.region_role}-rg"
  description = "All resources for Besu deployment ${var.deletion_group} ${var.region_role} region. Used for visibility and by the full-delete script."

  resource_query {
    # TAG_FILTERS_1_0 is the tag-based query type.
    type = "TAG_FILTERS_1_0"

    query = jsonencode({
      ResourceTypeFilters = ["AWS::AllSupported"]
      TagFilters = [
        {
          Key    = "Project"
          Values = [var.project_name]
        },
        {
          Key    = "DeletionGroup"
          Values = [var.deletion_group]
        }
      ]
    })
  }

  tags = merge(var.tags, {
    Name      = "${var.name_prefix}-${var.region_role}-rg"
    Component = "resource-group"
  })
}

output "resource_group_name" {
  description = "Name of the AWS Resource Group."
  value       = aws_resourcegroups_group.this.name
}

output "resource_group_arn" {
  description = "ARN of the AWS Resource Group."
  value       = aws_resourcegroups_group.this.arn
}
