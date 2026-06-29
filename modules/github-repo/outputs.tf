output "repo_name" {
  description = "Repository name."
  value       = github_repository.this.name
}

output "repo_node_id" {
  description = "Repository GraphQL node ID (for branch protection in other stacks)."
  value       = github_repository.this.node_id
}

output "repo_html_url" {
  description = "Repository web URL."
  value       = github_repository.this.html_url
}
