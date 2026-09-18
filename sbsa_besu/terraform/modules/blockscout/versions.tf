terraform {
  required_providers {
    helm   = { source = "hashicorp/helm", version = ">= 2.13" }
    random = { source = "hashicorp/random", version = ">= 3.5" }
  }
}
