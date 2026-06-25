variable "aws_region" {
  description = "AWS region to deploy all proxy lambdas, API gateways, and secrets into"
  type        = string
  default     = "us-east-2"
}
