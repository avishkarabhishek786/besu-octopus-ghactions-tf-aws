output "projects" {
  value = {
    infra      = octopusdeploy_project.infra.id
    workloads  = octopusdeploy_project.workloads.id
    validators = octopusdeploy_project.validators.id
  }
}

output "runner_worker_pools" {
  description = "install-tentacle.sh must register the runner into its environment's pool, by this name."
  value       = { for k, p in octopusdeploy_static_worker_pool.runner : k => p.name }
}

output "aws_accounts" {
  value = { for k, a in octopusdeploy_aws_openid_connect_account.deploy : k => a.id }
}
