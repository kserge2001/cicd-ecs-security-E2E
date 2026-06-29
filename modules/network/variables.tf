variable "name" {
  description = "Name/tag prefix for the VPC and its resources."
  type        = string
}

variable "vpc_cidr" {
  description = "CIDR block for the VPC."
  type        = string
  default     = "10.20.0.0/16"
}

variable "az_count" {
  description = "Number of AZs / public subnets to spread across."
  type        = number
  default     = 2
}
