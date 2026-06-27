output "api_urls" {
  description = "Live invoke URL for every proxy, keyed by lambda name"
  value       = { for k, m in module.lambda : k => m.api_url }
}

output "lambda_arns" {
  description = "Lambda ARN for every proxy, keyed by lambda name"
  value       = { for k, m in module.lambda : k => m.lambda_arn }
}

output "secret_names" {
  description = "Secret names created in Secrets Manager. Fill these in manually after apply."
  value       = { for k, m in module.secret : k => m.name }
}

output "api_key_secret_names" {
  description= "Secrets Manager secret name per proxy holding its API key . Retrieve via CLI / console"
  value       = { for k, m in module.lambda : k => m.api_key_secret_name }
}