# modules/ecs-env/variables.tf

variable "name" {
  description = "Name prefix for all resources in this environment (e.g. pipeline-lab-dev)."
  type        = string
}

variable "aws_region" {
  description = "AWS region (used for the awslogs log configuration)."
  type        = string
}

variable "vpc_id" {
  description = "VPC the ALB / ECS service live in."
  type        = string
}

variable "subnet_ids" {
  description = "Public subnet IDs for the ALB and Fargate tasks."
  type        = list(string)
}

variable "acm_certificate_arn" {
  description = "ARN of the ACM certificate for the HTTPS listener."
  type        = string
}

variable "hosted_zone_id" {
  description = "Route 53 hosted zone ID for the DNS alias record."
  type        = string
}

variable "record_fqdn" {
  description = "Fully-qualified name for the env record (e.g. dev.example.com)."
  type        = string
}

variable "container_name" {
  description = "Name of the container in the task definition."
  type        = string
}

variable "container_image" {
  description = "Initial container image. The pipeline overwrites this on deploy."
  type        = string
}

variable "container_port" {
  description = "Port the container listens on."
  type        = number
}

variable "cpu" {
  description = "Fargate task CPU units."
  type        = string
}

variable "memory" {
  description = "Fargate task memory (MiB)."
  type        = string
}

variable "desired_count" {
  description = "Initial desired task count. The pipeline manages it afterwards."
  type        = number
}

variable "execution_role_arn" {
  description = "ECS task execution role ARN (pulls images, writes logs)."
  type        = string
}
