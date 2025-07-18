variable "aws_region" {
  description = "AWS region"
  type        = string
  default     = "us-east-1"
}

variable "project_name" {
  description = "Project name for resource naming"
  type        = string
  default     = "odoo-demo"
}

variable "vpc_cidr" {
  description = "VPC CIDR block"
  type        = string
  default     = "10.0.0.0/16"
}

variable "db_name" {
  description = "Database name"
  type        = string
  default     = "odoo"
}

variable "db_username" {
  description = "Database username"
  type        = string
  default     = "odoo"
}

variable "ssh_key_name" {
  description = "AWS EC2 Key Pair name to use for SSH access"
  type        = string
}

