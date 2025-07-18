terraform {
  required_version = ">= 1.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = var.aws_region
}

# Data sources
data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"]

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd/ubuntu-focal-20.04-amd64-server-*"]
  }

  filter {
    name   = "architecture"
    values = ["x86_64"]
  }

  filter {
    name   = "root-device-type"
    values = ["ebs"]
  }
}

data "aws_availability_zones" "available" {
  state = "available"
}

# Generate random password for RDS
resource "random_password" "db_password" {
  length  = 16
  special = false # Avoid special chars for simplicity
}

#============================================================================
# VPC using public module
#============================================================================
module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.0"

  name = "${var.project_name}-vpc"
  cidr = var.vpc_cidr

  azs              = slice(data.aws_availability_zones.available.names, 0, 2)
  private_subnets  = [cidrsubnet(var.vpc_cidr, 8, 1), cidrsubnet(var.vpc_cidr, 8, 2)]
  public_subnets   = [cidrsubnet(var.vpc_cidr, 8, 101), cidrsubnet(var.vpc_cidr, 8, 102)]
  database_subnets = [cidrsubnet(var.vpc_cidr, 8, 201), cidrsubnet(var.vpc_cidr, 8, 202)]

  # Cost optimization: single NAT gateway
  enable_nat_gateway     = true
  single_nat_gateway     = true
  one_nat_gateway_per_az = false

  enable_dns_hostnames = true
  enable_dns_support   = true

  # Basic tags
  tags = {
    Project     = var.project_name
    Environment = "demo"
  }
}

#============================================================================
# Security Groups
#============================================================================
resource "aws_security_group" "load_balancer" {
  name_prefix = "${var.project_name}-lb-"
  vpc_id      = module.vpc.vpc_id

  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${var.project_name}-lb-sg"
  }
}

resource "aws_security_group" "app_servers" {
  name_prefix = "${var.project_name}-app-"
  vpc_id      = module.vpc.vpc_id

  ingress {
    from_port       = 8069
    to_port         = 8069
    protocol        = "tcp"
    security_groups = [aws_security_group.load_balancer.id]
  }

  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
  }

  # NFS access
  ingress {
    from_port = 2049
    to_port   = 2049
    protocol  = "tcp"
    self      = true
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${var.project_name}-app-sg"
  }
}

resource "aws_security_group" "database" {
  name_prefix = "${var.project_name}-db-"
  vpc_id      = module.vpc.vpc_id

  ingress {
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    security_groups = [aws_security_group.app_servers.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${var.project_name}-db-sg"
  }
}

resource "aws_security_group" "efs" {
  name_prefix = "${var.project_name}-efs-"
  vpc_id      = module.vpc.vpc_id

  ingress {
    from_port       = 2049
    to_port         = 2049
    protocol        = "tcp"
    security_groups = [aws_security_group.app_servers.id]
  }

  tags = {
    Name = "${var.project_name}-efs-sg"
  }
}

#============================================================================
# RDS using public module (Free Tier)
#============================================================================
module "rds" {
  source  = "terraform-aws-modules/rds/aws"
  version = "~> 6.0"

  identifier = "${var.project_name}-db"

  # Free tier settings
  engine               = "postgres"
  engine_version       = "15.8"
  family               = "postgres15"
  major_engine_version = "15"
  instance_class       = "db.t3.micro"

  allocated_storage     = 20
  max_allocated_storage = 100
  storage_encrypted     = false # Free tier limitation

  db_name  = var.db_name
  username = var.db_username
  password = random_password.db_password.result
  port     = 5432

  multi_az               = false # Free tier is single AZ
  publicly_accessible    = false
  vpc_security_group_ids = [aws_security_group.database.id]

  maintenance_window              = "Mon:00:00-Mon:03:00"
  backup_window                   = "03:00-06:00"
  enabled_cloudwatch_logs_exports = ["postgresql"]
  create_cloudwatch_log_group     = true

  backup_retention_period = 1 # Minimum for free tier
  skip_final_snapshot     = true
  deletion_protection     = false

  performance_insights_enabled = false # Not available on t3.micro
  create_monitoring_role       = false

  # Networking
  db_subnet_group_name = module.vpc.database_subnet_group
  subnet_ids           = module.vpc.database_subnets

  tags = {
    Project     = var.project_name
    Environment = "demo"
  }
}

#============================================================================
# EFS for shared storage
#============================================================================
resource "aws_efs_file_system" "main" {
  creation_token = "${var.project_name}-efs"

  performance_mode                = "generalPurpose"
  throughput_mode                 = "provisioned"
  provisioned_throughput_in_mibps = 1 # Minimum for cost

  encrypted = true

  tags = {
    Name    = "${var.project_name}-efs"
    Project = var.project_name
  }
}

resource "aws_efs_mount_target" "main" {
  count = length(module.vpc.private_subnets)

  file_system_id  = aws_efs_file_system.main.id
  subnet_id       = module.vpc.private_subnets[count.index]
  security_groups = [aws_security_group.efs.id]
}

#============================================================================
# Load Balancer VM (with static IP)
#============================================================================
resource "aws_eip" "load_balancer" {
  domain = "vpc"

  tags = {
    Name = "${var.project_name}-lb-eip"
  }
}

resource "aws_instance" "load_balancer" {
  ami           = data.aws_ami.ubuntu.id
  instance_type = "t3.micro" # Free tier
  key_name      = var.ssh_key_name

  subnet_id                   = module.vpc.public_subnets[0]
  vpc_security_group_ids      = [aws_security_group.load_balancer.id]
  associate_public_ip_address = true

  depends_on = [aws_instance.app_servers]

  tags = {
    Name    = "${var.project_name}-load-balancer"
    Project = var.project_name
  }
}

resource "aws_eip_association" "load_balancer" {
  instance_id   = aws_instance.load_balancer.id
  allocation_id = aws_eip.load_balancer.id
}

#============================================================================
# App Server VMs
#============================================================================
resource "aws_instance" "app_servers" {
  count = 2

  ami           = data.aws_ami.ubuntu.id
  instance_type = "t3.micro" # Free tier
  key_name      = var.ssh_key_name

  subnet_id              = module.vpc.private_subnets[count.index % length(module.vpc.private_subnets)]
  vpc_security_group_ids = [aws_security_group.app_servers.id]

  depends_on = [
    module.rds,
    aws_efs_mount_target.main
  ]

  tags = {
    Name    = "${var.project_name}-app-${count.index + 1}"
    Project = var.project_name
  }
}