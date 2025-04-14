terraform {
  backend "s3" {
    bucket         = "rgers3.tfstate-backend.com"  # Must match the bucket name above
    key            = "coaching17/terraform.tfstate"        # State file path
    region         = "us-east-1"                # Same as provider
    dynamodb_table = "terraform-state-locks"    # If using DynamoDB
    # use_lockfile   = true                       # replaces dynamodb_table                
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
  prefix = "myapp" # Change to your preferred prefix
}

# --- VPC & Networking ---
resource "aws_vpc" "main" {
  cidr_block = "10.0.0.0/16"
  tags = {
    Name = "${local.prefix}-vpc"
  }
}

resource "aws_subnet" "public" {
  count             = 2
  vpc_id            = aws_vpc.main.id
  cidr_block        = "10.0.${count.index}.0/24"
  availability_zone = element(data.aws_availability_zones.available.names, count.index)
  tags = {
    Name = "${local.prefix}-public-subnet-${count.index}"
  }
}

resource "aws_internet_gateway" "gw" {
  vpc_id = aws_vpc.main.id
  tags = {
    Name = "${local.prefix}-igw"
  }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.gw.id
  }
  tags = {
    Name = "${local.prefix}-public-rt"
  }
}

resource "aws_route_table_association" "public" {
  count          = 2
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

# --- Security Group for ECS Tasks ---
resource "aws_security_group" "ecs" {
  name        = "${local.prefix}-ecs-sg"
  vpc_id      = aws_vpc.main.id
  description = "Allow inbound HTTP traffic"

  ingress {
    from_port   = 8080
    to_port     = 8080
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"] # Restrict in production!
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
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