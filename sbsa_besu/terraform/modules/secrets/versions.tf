terraform {
  required_version = ">= 1.5.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.60"
    }
    # random generates keystore/truststore/JWT secrets that Terraform legitimately
    # owns (unlike secp256k1 node keys — see the module header).
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
    # helm installs the Secrets Store CSI AWS provider DaemonSet (in-cluster).
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.14"
    }
  }
}
