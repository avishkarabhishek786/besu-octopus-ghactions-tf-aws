# Local state on purpose. This is a throwaway fixture, not infrastructure of
# record — the same choice mimic_vpc and mimic_egress make. A remote backend
# would outlive the thing it describes.
terraform {
  backend "local" {}
}
