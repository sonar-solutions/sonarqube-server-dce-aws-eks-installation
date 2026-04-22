# Route53 DNS Configuration
# This file contains Route53 resources to automatically configure DNS records
# for the SonarQube domain and ACM certificate validation

# Find existing Route53 hosted zone (assumes it exists)
data "aws_route53_zone" "existing" {
  name         = var.domain_name
  private_zone = false
}

# Data source to get the NLB created by the AWS Load Balancer Controller for the SonarQube service
data "aws_lb" "sonarqube_nlb" {
  depends_on = [
    helm_release.sonarqube
  ]

  tags = {
    "kubernetes.io/service-name" = "default/sonarqube-sonarqube-dce"
  }
}

# Create A record (alias) pointing to the NLB
resource "aws_route53_record" "sonarqube" {
  zone_id = data.aws_route53_zone.existing.zone_id
  name    = "${var.host_name}.${var.domain_name}"
  type    = "A"

  alias {
    name                   = data.aws_lb.sonarqube_nlb.dns_name
    zone_id                = data.aws_lb.sonarqube_nlb.zone_id
    evaluate_target_health = true
  }

  depends_on = [
    data.aws_lb.sonarqube_nlb
  ]
}

# Create validation records for ACM certificate
resource "aws_route53_record" "acm_validation" {
  for_each = {
    for dvo in aws_acm_certificate.sonarqube.domain_validation_options : dvo.domain_name => {
      name   = dvo.resource_record_name
      record = dvo.resource_record_value
      type   = dvo.resource_record_type
    }
  }

  allow_overwrite = true
  name            = each.value.name
  records         = [each.value.record]
  ttl             = 60
  type            = each.value.type
  zone_id         = data.aws_route53_zone.existing.zone_id
}

# Certificate validation
resource "aws_acm_certificate_validation" "sonarqube" {
  certificate_arn         = aws_acm_certificate.sonarqube.arn
  validation_record_fqdns = [for record in aws_route53_record.acm_validation : record.fqdn]
  
  depends_on = [
    aws_route53_record.acm_validation
  ]
}

# Output for DNS record verification
output "dns_record_name" {
  description = "The DNS record name that was created"
  value       = aws_route53_record.sonarqube.name
  sensitive   = false
}

output "dns_record_target" {
  description = "The DNS record target (load balancer DNS)"
  value       = aws_route53_record.sonarqube.alias[0].name
  sensitive   = false
}

output "route53_name_servers" {
  description = "Name servers for the existing Route53 hosted zone"
  value       = data.aws_route53_zone.existing.name_servers
  sensitive   = false
}

output "hosted_zone_id" {
  description = "ID of the existing hosted zone"
  value       = data.aws_route53_zone.existing.zone_id
  sensitive   = false
}
