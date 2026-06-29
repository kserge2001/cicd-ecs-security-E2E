variable "name" {
  description = "ECR repository name."
  type        = string
}

variable "image_tag_mutability" {
  description = "MUTABLE or IMMUTABLE. IMMUTABLE is recommended for prod."
  type        = string
  default     = "MUTABLE"
}

variable "force_delete" {
  description = "Allow destroy even when the repository still holds images (lab convenience)."
  type        = bool
  default     = false
}
