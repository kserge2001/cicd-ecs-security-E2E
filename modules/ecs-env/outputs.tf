# modules/ecs-env/outputs.tf

output "cluster_name" {
  description = "ECS cluster name (the pipeline targets this)."
  value       = aws_ecs_cluster.this.name
}

output "service_name" {
  description = "ECS service name (the pipeline updates this)."
  value       = aws_ecs_service.this.name
}

output "task_family" {
  description = "Task definition family (the pipeline registers new revisions here)."
  value       = aws_ecs_task_definition.this.family
}

output "alb_dns_name" {
  description = "Public DNS name of the ALB."
  value       = aws_lb.this.dns_name
}

output "record_fqdn" {
  description = "The environment's FQDN."
  value       = aws_route53_record.this.fqdn
}
