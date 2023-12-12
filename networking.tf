# create a variable for region and app name
variable "region" {
  default = "us-east-1"
}
variable "app_name" {
  default = "GxSChatbot"
}

# create a new public VPC with CIDR 10.0.0.0/24
resource "aws_vpc" "main" {
  cidr_block = "10.0.0.0/24"
}

# create a new public subnet in the VPC
resource "aws_subnet" "main" {
  vpc_id     = aws_vpc.main.id
  cidr_block = "10.0.0.0/24"
}

# create a new internet gateway
resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id
}

# attach the internet gateway to the VPC
resource "aws_internet_gateway_attachment" "main" {
  vpc_id      = aws_vpc.main.id
  internet_gateway_id = aws_internet_gateway.main.id
}

# create a new public route table
resource "aws_route_table" "main" {
  vpc_id = aws_vpc.main.id
}

# associate the public subnet with the public route table
resource "aws_route_table_association" "main" {
  subnet_id      = aws_subnet.main.id
  route_table_id = aws_route_table.main.id
}

# create a new public route
resource "aws_route" "main" {
  route_table_id         = aws_route_table.main.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.main.id
}

# create a new security group
resource "aws_security_group" "main" {
  name        = "main"
  description = "Allow SSH inbound traffic"
  vpc_id      = aws_vpc.main.id

  # TODO update the security group rules
  ingress {
    description = "SSH from VPC"
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
}

# create an internet facing elb in the vpc
# TODO enter the SSL cert if required
resource "aws_elb" "main" {
  subnets                   = [aws_subnet.main.id]
  cross_zone_load_balancing = true
  security_groups           = [aws_security_group.main.id]

  listener {
    instance_port      = 80
    instance_protocol  = "http"
    lb_port            = 443
    lb_protocol        = "https"
  }

  health_check {
    healthy_threshold   = 2
    unhealthy_threshold = 2
    timeout             = 3
    target              = "HTTP:80/"
    interval            = 30
  }
}

## TODO not setting up WAF but this should be done 
## as it's best practice to do so

#### SETUP CLOUDFRONT ####
# setup cloudfront distribution with the elb with the parameters to redirect to HTTPS,
# disable cache and allow all methods, no geo restrictions
resource "aws_cloudfront_distribution" "main" {
  origin {
    domain_name = aws_elb.main.dns_name
    origin_id   = "elb"
  }

  enabled         = true
  is_ipv6_enabled = true

  default_cache_behavior {
    allowed_methods  = ["GET", "HEAD", "OPTIONS", "PUT", "POST", "PATCH", "DELETE"]
    cached_methods   = ["GET", "HEAD"]
    target_origin_id = "elb"

    forwarded_values {
      query_string = true

      cookies {
        forward = "none"
      }
    }

    viewer_protocol_policy = "redirect-to-https"
    min_ttl                = 0
    default_ttl            = 0
    max_ttl                = 0
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  viewer_certificate {
    cloudfront_default_certificate = true
  }
}

#### SETUP ECS ####
## create a new ECS cluster in the same vpc and enable container insights
resource "aws_ecs_cluster" "main" {
  name = "main"
  setting {
    name  = "containerInsights"
    value = "enabled"
  }
}

#### SETUP COGNITO ####
## create a cognito user pool without MFA 
resource "aws_cognito_user_pool" "main" {
  name = "main"
}

## add domian for user pool set the prefix to app_name
resource "aws_cognito_user_pool_domain" "main" {
  domain       = "${var.app_name}.auth.${var.region}.amazoncognito.com"
  user_pool_id = aws_cognito_user_pool.main.id
}

## add a client called cognito-appClient with the callback url set to https://${aws_cloudfront_distribution.main.domain_name}
resource "aws_cognito_user_pool_client" "main" {
  name                                 = "cognito-appClient"
  user_pool_id                         = aws_cognito_user_pool.main.id
  callback_urls                        = ["http://localhost:3000/api/auth/callback/cognito","https://${aws_cloudfront_distribution.main.domain_name}/api/auth/callback/cognito"]
  allowed_oauth_flows_user_pool_client = true
}

## setup secrets for the user pool called appClientIdSSM with the value userPoolClientId and parameter `/${this.appName}/COGNTIO_CLIENT_ID`
resource "aws_secretsmanager_secret" "app_client_id" {
  name = "appClientIdSSM"
}

resource "aws_secretsmanager_secret_version" "app_client_id" {
  secret_id     = aws_secretsmanager_secret.app_client_id.id
  secret_string = aws_cognito_user_pool_client.main.id
}
