output "id" {
  value = aws_iam_access_key.this.id
}

output "secret" {
  value     = aws_iam_access_key.this.secret
  sensitive = true
}

output "ecr_url" {
  value = aws_ecr_repository.this.repository_url
}

output "lb_dns_name" {
  value = aws_lb.this.dns_name
}

output "ecs_url" {
  value = aws_ecs_service.this.load_balancer
}