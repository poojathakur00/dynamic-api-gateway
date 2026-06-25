variable "name" {
  description = "Unique name for this proxy — used for the lambda, IAM role, and API Gateway"
  type        = string
}

variable "secret_name" {
  description = "Name of the Secrets Manager secret this lambda reads at runtime (env var)"
  type        = string
}

variable "secret_arn" {
  description = "ARN of the Secrets Manager secret this lambda is allowed to read (IAM policy)"
  type        = string
}

variable "swagger_path" {
  description = "Path to this proxy's clean swagger/OpenAPI file (no AWS extensions needed)"
  type        = string
}

variable "auth_type" {
  description = "Type of authentication to use for this lambda"
  type        = string
}

# --- Zip the shared lambda code. Same source dir every time, unique zip per instance. ---
data "archive_file" "this" {
  type        = "zip"
  source_dir  = "${path.root}/lambda_code"
  output_path = "${path.root}/builds/${var.name}.zip"
}

# --- IAM Role ---
resource "aws_iam_role" "this" {
  name = "${var.name}-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
    }]
  })
}

# Basic CloudWatch Logs permissions — every lambda needs this to write logs
resource "aws_iam_role_policy_attachment" "logs" {
  role       = aws_iam_role.this.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

# Scoped permission: this lambda can read exactly its own secret, nothing else
resource "aws_iam_role_policy" "secrets_access" {
  name = "${var.name}-secrets-access"
  role = aws_iam_role.this.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = "secretsmanager:GetSecretValue"
      Resource = var.secret_arn
    }]
  })
}

# --- Lambda ---
resource "aws_lambda_function" "this" {
  function_name = var.name
  role          = aws_iam_role.this.arn
  handler       = "handler.handler"
  runtime       = "python3.12"

  filename         = data.archive_file.this.output_path
  source_code_hash = data.archive_file.this.output_base64sha256

  environment {
    variables = {
      SECRET_NAME = var.secret_name
      AUTH_TYPE   = var.auth_type
    }
  }
}

# --- Dynamically inject the AWS-specific integration into every path/method. ---
# Backend devs write plain OpenAPI — no AWS knowledge required.
# --- Dynamically inject the AWS-specific integration into every path/method. ---
# Backend devs write plain OpenAPI — no AWS knowledge required.
locals {
  swagger_raw = jsondecode(file(var.swagger_path))

  # Only these keys under a path item are actual HTTP methods. A path item
  # can also carry sibling keys like "parameters", "summary", or "$ref" —
  # those must be left untouched, not merged with an integration block.
  http_methods = ["get", "put", "post", "delete", "options", "head", "patch", "trace"]

  swagger_with_integration = merge(local.swagger_raw, {
    paths = {
      for path, methods in local.swagger_raw.paths : path => merge(
        methods,
        {
          for method, definition in methods : method => merge(definition, {
            "x-amazon-apigateway-integration" = {
              type       = "aws_proxy"
              httpMethod = "POST"
              uri        = aws_lambda_function.this.invoke_arn
            }
          })
          if contains(local.http_methods, method)
        }
      )
    }
  })
}

# --- API Gateway ---
resource "aws_api_gateway_rest_api" "this" {
  name = var.name
  body = jsonencode(local.swagger_with_integration)
}

resource "aws_api_gateway_deployment" "this" {
  rest_api_id = aws_api_gateway_rest_api.this.id

  triggers = {
    redeployment = sha1(jsonencode(local.swagger_with_integration))
  }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_api_gateway_stage" "this" {
  rest_api_id   = aws_api_gateway_rest_api.this.id
  deployment_id = aws_api_gateway_deployment.this.id
  stage_name    = "prod"
}

# --- Lambda Permission: let API Gateway actually invoke this lambda ---
resource "aws_lambda_permission" "this" {
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.this.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_api_gateway_rest_api.this.execution_arn}/*/*"
}

# --- Outputs ---
output "api_url" {
  value = aws_api_gateway_stage.this.invoke_url
}

output "lambda_arn" {
  value = aws_lambda_function.this.arn
}
