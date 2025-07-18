output "load_balancer_public_ip" {
  description = "Public IP of the load balancer EC2 instance"
  value       = aws_eip.load_balancer.public_ip
}

output "app_servers_private_ips" {
  description = "Private IPs of Odoo app server instances"
  value       = [for instance in aws_instance.app_servers : instance.private_ip]
}

output "vpc_id" {
  description = "VPC ID created for this environment"
  value       = module.vpc.vpc_id
}

output "efs_dns_name" {
  description = "EFS DNS name for mounting NFS"
  value       = aws_efs_file_system.main.dns_name
}

output "db_password" {
  description = "Database password (sensitive)"
  value       = random_password.db_password.result
  sensitive   = true
}
