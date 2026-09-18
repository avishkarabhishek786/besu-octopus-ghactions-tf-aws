terraform {
  required_version = ">= 1.5.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.60"
    }
    # tls drives the self-managed CA path (CA key + self-signed CA cert) with no
    # external dependency. Only used when ca_mode != "aws".
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
  }
}
