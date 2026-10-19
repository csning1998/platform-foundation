
output "project_id" {
  description = "Numeric identifier of the GitLab project of this repository."
  value       = module.provisioner_gitlab_project.project_id
}
