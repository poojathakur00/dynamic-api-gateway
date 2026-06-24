variable "name" {
  description = "Name of the secret to create in AWS Secrets Manager"
  type        = string
}

resource "aws_secretsmanager_secret" "this" {
  name = var.name
}

output "arn" {
  value = aws_secretsmanager_secret.this.arn
}

output "name" {
  value = aws_secretsmanager_secret.this.name
}
