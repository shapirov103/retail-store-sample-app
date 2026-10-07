resource "aws_security_group" "this" {
  name        = "${var.environment_name}-${var.service_name}-task"
  description = "${var.service_name} tasks"
  vpc_id      = var.vpc_id
  tags        = var.tags

  # Upstream allows 0.0.0.0/0 here. Tasks only need traffic from inside the VPC
  # (ALB and Service Connect peers), so ingress is limited to the VPC CIDR.
  ingress {
    description = "App port from inside the VPC"
    protocol    = "tcp"
    from_port   = 8080
    to_port     = 8080
    cidr_blocks = [var.vpc_cidr]
  }

  egress {
    description = "All outbound (image pulls, AWS APIs, peers)"
    protocol    = "-1"
    from_port   = 0
    to_port     = 0
    cidr_blocks = ["0.0.0.0/0"]
  }
}
