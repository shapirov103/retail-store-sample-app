resource "aws_security_group" "alb" {
  name        = "${var.environment_name}-alb"
  description = "Public HTTP to the store UI"
  vpc_id      = local.vpc_id

  # Public on purpose: the audience can open the store. No authentication;
  # this is a demo storefront with no real data. Tear down after the event.
  ingress {
    description = "HTTP from anywhere"
    protocol    = "tcp"
    from_port   = 80
    to_port     = 80
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    description = "To tasks in the VPC"
    protocol    = "tcp"
    from_port   = 8080
    to_port     = 8080
    cidr_blocks = [local.vpc_cidr]
  }
}

resource "aws_lb" "ui" {
  name               = "${var.environment_name}-ui"
  load_balancer_type = "application"
  subnets            = local.public_subnets
  security_groups    = [aws_security_group.alb.id]
}

resource "aws_lb_target_group" "ui" {
  name                 = "${var.environment_name}-ui"
  port                 = 8080
  protocol             = "HTTP"
  target_type          = "ip"
  vpc_id               = local.vpc_id
  deregistration_delay = 30

  # Checks only the UI's own health. It does not call catalog or carts, which is
  # why the ALB stays green while catalog is broken.
  health_check {
    enabled             = true
    path                = "/actuator/health"
    port                = "traffic-port"
    interval            = 30
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 3
  }
}

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.ui.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.ui.arn
  }
}
