terraform {
  backend "s3" {
    bucket         = "rgers3.tfstate-backend.com"  
    key            = "coaching17/terraform.tfstate"        # State file path
    region         = "us-east-1"                # Same as provider
    dynamodb_table = "terraform-state-locks"    # If using DynamoDB              
    encrypt        = true                       # Use encryption
  }
}
provider "aws" {
  region = "us-east-1" # Change if needed
}
data "aws_caller_identity" "current" {}
data "aws_region" "current" {}
data "aws_availability_zones" "available" {  # <-- This was missing
  state = "available"
}

locals {
  prefix = "rger"
  common_tags = {
    Project   = "Coaching17"
    Terraform = "true"
  }
}

# Network Module
module "network" {
  source = "./modules/network"
  
  prefix              = local.prefix
  vpc_cidr            = "10.0.0.0/16"
  public_subnet_cidrs = ["10.0.1.0/24", "10.0.2.0/24"]
  availability_zones  = slice(data.aws_availability_zones.available.names, 0, 2)
  tags                = local.common_tags
}

# ECR Module
module "ecr" {
  source = "./modules/ecr"
  
  repository_name = "${local.prefix}-flask-app"
  tags           = local.common_tags
}

# ECS Module
module "ecs" {
  source = "./modules/ecs"
  
  prefix              = local.prefix
  vpc_id             = module.network.vpc_id
  public_subnet_ids  = module.network.public_subnet_ids
  ecr_repository_url = module.ecr.repository_url
  container_port     = 8080
  tags               = local.common_tags
  
  depends_on = [module.ecr]
}

# IAM Module
module "iam" {
  source = "./modules/iam"
  
  prefix         = local.prefix
  s3_bucket_arn  = "arn:aws:s3:::rgers3.tfstate-backend.com"
  dynamodb_table = "terraform-state-locks"
  tags           = local.common_tags
}


# --- ECR Repository ---
resource "aws_ecr_repository" "app" {
  name = "${local.prefix}-ecr"
}

# --- ECS Cluster & Service ---
module "ecs" {
  depends_on = [ aws_ecr_repository.app ]
  source  = "terraform-aws-modules/ecs/aws"
  version = "~> 5.0"

  cluster_name = "${local.prefix}-ecs"
  fargate_capacity_providers = {
    FARGATE = {
      default_capacity_provider_strategy = {
        weight = 100
      }
    }
  }

  services = {
    myapp-service = {
      # Use a static map structure for container_definitions
      container_definitions = {
        (var.container_name) = { #dynamic key fr var.tf
          name      = var.container_name #reused here
          essential = true
          image     = "${aws_ecr_repository.app.repository_url}:latest"
          cpu       = 512
          memory    = 1024 # Important: Add these dummy entries to prevent unknown values
          port_mappings = [
            {
              containerPort = 8080
              hostPort      = 8080
              protocol     = "tcp"
            }
          ]
          # Add required fields
          environment = [] 
          secrets     = []
          mount_points = []
          volumes_from = []
        }
      }
      assign_public_ip                   = true
      deployment_minimum_healthy_percent = 100
      subnet_ids                         = aws_subnet.public[*].id
      security_group_ids                 = [aws_security_group.ecs.id]
      # Add these required fields
      enable_execute_command = true
      task_exec_iam_role_arn = aws_iam_role.ecs_exec_role.arn
    }
  }
}
# --- IAM Role for ECS Exec ---
resource "aws_iam_role" "ecs_exec_role" {
  name_prefix = "${local.prefix}-ecs-exec-role" #add random suffix

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "ecs-tasks.amazonaws.com"
        }
      }
    ]
  })
  lifecycle {
    create_before_destroy = true  # Helps with replacements
  }
}

resource "aws_iam_role_policy" "ecs_s3_access" {
  name_prefix = "${local.prefix}-s3-access"
  role = aws_iam_role.ecs_exec_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "s3:ListBucket",
          "s3:GetObject",
          "s3:PutObject",
          "s3:DeleteObject"
        ]
        Resource = [
          "arn:aws:s3:::rgers3.tfstate-backend.com",
          "arn:aws:s3:::rgers3.tfstate-backend.com/*",
          "arn:aws:dynamodb:us-east-1:255945442255:table/terraform-state-locks"
        ]
      }
    ]
  })
  lifecycle {
    create_before_destroy = true  # Helps with replacements
  }
}

resource "aws_iam_role_policy_attachment" "ecs_exec_policy" {
  role       = aws_iam_role.ecs_exec_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}
# --- Outputs ---
output "ecr_repository_url" {
  value = aws_ecr_repository.app.repository_url
}

output "ecs_service_name" {
  value = module.ecs.services["myapp-service"].name
}

output "ecs_exec_role_arn" {
  value = aws_iam_role.ecs_exec_role.arn  # Reference the actual IAM role resource
  description = "ARN of the ECS task execution IAM role"
}
output "container_name" {
  value       = var.container_name
  description = "Name of the deployed container"
}
