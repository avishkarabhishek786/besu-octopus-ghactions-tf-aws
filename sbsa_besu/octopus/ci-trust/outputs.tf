output "service_account" {
  description = "The CI service account's user id. Its SERVICE ACCOUNT ID — the GUID release.yml needs as the GitHub variable OCTOPUS_SERVICE_ACCOUNT_ID — is not exposed by the provider; read it from the user's page in Octopus, or: GET <server>/api/serviceaccounts/<this id>/oidcidentities/v1?skip=0&take=1 -> .ExternalId"
  value       = octopusdeploy_user.ci.id
}

output "trusted_subjects" {
  description = "Exactly which GitHub subjects may sign in. Compare with the workflow's 'Show the OIDC subject' line if the login is refused."
  value       = local.subjects
}
