terraform {
  required_version = ">= 1.11"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.60"
    }
    local = {
      source  = "hashicorp/local"
      version = ">= 2.5"
    }
  }
}
