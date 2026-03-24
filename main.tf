data "aws_ami" "app_ami" {
  most_recent = true

  filter {
    name   = "name"
    values = ["amzn2-ami-hvm-*-x86_64-gp2"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }

  owners = ["137112412989"] # Amazon
}

module "blog_vpc"{
  source = "terraform-aws-modules/vpc/aws"

  name = "dev"
  cidr = "10.0.0.0/16"

  azs             = ["us-west-2a", "us-west-2b", "us-west-2c"]
  private_subnets = ["10.0.1.0/24", "10.0.2.0/24", "10.0.3.0/24"]
  public_subnets  = ["10.0.101.0/24", "10.0.102.0/24", "10.0.103.0/24"]

  enable_nat_gateway = true

  tags = {
    Terraform = "true"
    Environment = "dev"
  }
}

module "blog_sg" {
  source  = "terraform-aws-modules/security-group/aws"
  version = "5.3.1"
  name    = "blog"

  vpc_id = module.blog_vpc.vpc_id

  ingress_rules       = ["http-80-tcp","https-443-tcp"]
  ingress_cidr_blocks = ["0.0.0.0/0"]

  egress_rules       = ["all-all"]
  egress_cidr_blocks = ["0.0.0.0/0"]  
}

module "blog_alb" {
  source = "terraform-aws-modules/alb/aws"

  name    = "blog-alb"
  vpc_id  = module.blog_vpc.vpc_id
  subnets = module.blog_vpc.public_subnets

  security_groups = [module.blog_sg.security_group_id]
    
  listeners = {
    blog-http = {
      port     = 80
      protocol = "HTTP"
      forward = {
        target_group_arn = aws_lb_target_group.blog.arn
      }
    }
  }

  tags = {
    Environment = "dev"
  }
}

resource "aws_lb_target_group" "blog" {
  name     = "blog"
  port     = 80
  protocol = "HTTP"
  vpc_id   = module.blog_vpc.vpc_id

  health_check {
    path                = "/"
    protocol            = "HTTP"
    matcher             = "200-399"
    healthy_threshold   = 2
    unhealthy_threshold = 3
    timeout             = 5
    interval            = 30
  }
}

module "blog_autoscaling" {
  source  = "terraform-aws-modules/autoscaling/aws"
  version = "9.2.0"
            
  name = "blog"

  min_size = 1
  max_size = 2
  desired_capacity = 1
  health_check_type         = "ELB"
  health_check_grace_period = 600

  # Place app instances in private subnets (egress through NAT) behind public ALB
  vpc_zone_identifier = module.blog_vpc.private_subnets

  launch_template_name = "blog"

  security_groups = [module.blog_sg.security_group_id]

  instance_type = var.instance_type
  image_id      = data.aws_ami.app_ami.id

  # Bootstrap Apache so ALB target health checks pass and traffic can be served
  user_data = base64encode(<<-EOT
#!/bin/bash
set -xe
mkdir -p /var/www/html
echo "<h1>Blog app is running on $(hostname -f)</h1>" > /var/www/html/index.html

# Avoid package-install/network dependency during bootstrap:
# start a simple local HTTP server on port 80
nohup python3 -m http.server 80 --directory /var/www/html >/var/log/simple-http.log 2>&1 &
sleep 2
curl -I http://127.0.0.1/ || true
EOT
  )

  traffic_source_attachments = {
    blob-alb = {
      traffic_source_identifier = aws_lb_target_group.blog.arn
    }
  }
}
