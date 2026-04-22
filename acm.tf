# Generate SSL certificate with lifecycle management
resource "aws_acm_certificate" "sonarqube" {
  domain_name = "${var.host_name}.${var.domain_name}"
  validation_method = "DNS"

  lifecycle {
    create_before_destroy = true
  }

  tags = {
    Name = "${var.cluster_name}-acm"
    Environment = var.environment
    Owner = var.owner_tag
  }
}