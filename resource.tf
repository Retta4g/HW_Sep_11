# AWS Key Pair Resource for SSH Access
resource "aws_key_pair" "deployer" {
  key_name   = "fist-deployer-key"
  public_key = file("~/.ssh/id_ed25519.pub")
}

# Variables
variable "prefix" {
  type    = string
  default = "project-aug-28"
}

variable "instance_count" {
  type    = number
  default = 3
}

# Local Values
locals {
  instance_names = [for i in range(var.instance_count) : "${var.prefix}-ec2-${i + 1}"]
}

# AWS VPC
resource "aws_vpc" "main" {
  cidr_block = "172.16.0.0/16"
  tags = {
    Name = join("-", [var.prefix, "vpc"])
  }
}

# Internet Gateway for VPC
resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id
}

# Fetch available availability zones in the region
data "aws_availability_zones" "available" {
  state = "available"
}

# Create two subnets in different Availability Zones
resource "aws_subnet" "subnet_a" {
  vpc_id     = aws_vpc.main.id
  cidr_block = "172.16.0.0/24"
  availability_zone = data.aws_availability_zones.available.names[0]
  tags = {
    Name = join("-", [var.prefix, "subnet-a"])
  }
}

resource "aws_subnet" "subnet_b" {
  vpc_id     = aws_vpc.main.id
  cidr_block = "172.16.1.0/24"
  availability_zone = data.aws_availability_zones.available.names[1]
  tags = {
    Name = join("-", [var.prefix, "subnet-b"])
  }
}

# Route Table for VPC
resource "aws_route_table" "main" {
  vpc_id = aws_vpc.main.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }
}

# Associate Subnets with Route Table
resource "aws_route_table_association" "subnet_a" {
  subnet_id      = aws_subnet.subnet_a.id
  route_table_id = aws_route_table.main.id
}

resource "aws_route_table_association" "subnet_b" {
  subnet_id      = aws_subnet.subnet_b.id
  route_table_id = aws_route_table.main.id
}

# Security Group Module (group2)
module "group2" {
  source  = "app.terraform.io/02-spring-cloud/group2/security"
  version = "3.0.0"
  vpc_id  = aws_vpc.main.id

  security_groups = {
    "web" = {
      description = "Security Group for Web Tier"
      ingress_rules = [
        {
          to_port     = 22
          from_port   = 22
          cidr_blocks = ["0.0.0.0/0"]
          protocol    = "tcp"
          description = "ssh ingress rule"
        },
        {
          to_port     = 80
          from_port   = 80
          cidr_blocks = ["0.0.0.0/0"]
          protocol    = "tcp"
          description = "http ingress rule"
        },
        {
          to_port     = 443
          from_port   = 443
          cidr_blocks = ["0.0.0.0/0"]
          protocol    = "tcp"
          description = "https ingress rule"
        }
      ],
      egress_rules = [
        {
          to_port     = 0
          from_port   = 0
          cidr_blocks = ["0.0.0.0/0"]
          protocol    = "-1"
          description = "allow all outbound traffic"
        }
      ]
    }
  }
}

# Create Application Load Balancer (ALB)
resource "aws_lb" "web" {
  name               = "${var.prefix}-web-lb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [module.group2.security_group_id["web"]]
  subnets            = [aws_subnet.subnet_a.id, aws_subnet.subnet_b.id]

  tags = {
    Name = "${var.prefix}-alb"
  }
}

# Create Target Group for Load Balancer
resource "aws_lb_target_group" "web" {
  name     = "${var.prefix}-tg"
  port     = 80
  protocol = "HTTP"
  vpc_id   = aws_vpc.main.id

  health_check {
    path                = "/"
    protocol            = "HTTP"
    interval            = 30
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 2
  }

  tags = {
    Name = "${var.prefix}-tg"
  }
}

## Auto Scaling Launch Template
resource "aws_launch_template" "server" {
  name_prefix   = "${var.prefix}-lt"
  image_id      = "ami-066784287e358dad1"
  instance_type = "t2.micro"
  key_name      = aws_key_pair.deployer.key_name

  network_interfaces {
    associate_public_ip_address = true
    security_groups             = [module.group2.security_group_id["web"]]
    subnet_id                   = aws_subnet.subnet_a.id
  }

  # Encode the user data as base64
  user_data = base64encode(<<-EOF
              #!/bin/bash
              sudo yum update -y
              sudo yum install -y httpd
              sudo systemctl start httpd.service
              sudo systemctl enable httpd.service
              echo "<h1>Hello World from ${var.prefix}</h1>" | sudo tee /var/www/html/index.html
              sudo systemctl restart httpd.service
  EOF
  )
}


# Auto Scaling Group
resource "aws_autoscaling_group" "server" {
  desired_capacity     = var.instance_count
  max_size             = var.instance_count
  min_size             = 1
  vpc_zone_identifier  = [aws_subnet.subnet_a.id, aws_subnet.subnet_b.id]
  launch_template {
    id      = aws_launch_template.server.id
    version = "$Latest"
  }

  target_group_arns = [aws_lb_target_group.web.arn]

  tag {
    key                 = "Name"
    value               = "${var.prefix}-asg"
    propagate_at_launch = true
  }
}

# Output the Load Balancer DNS Name
output "load_balancer_dns_name" {
  value = aws_lb.web.dns_name
}
