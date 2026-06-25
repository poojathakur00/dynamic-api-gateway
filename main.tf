locals {
  lambdas = yamldecode(file("${path.module}/config/lambdas.yaml")).lambdas
}

# One secret "shell" per proxy. Terraform only creates the container —
# a human fills in the actual value (base_url, api_key, etc.) afterward
# in the AWS console. See the secret_names output below for the names.
module "secret" {
  for_each = { for l in local.lambdas : l.name => l }
  source   = "./modules/secrets_manager"

  name = each.value.secret_name
}

# One Lambda + API Gateway per proxy, fully driven by config/lambdas.yaml.
# Keyed identically to module.secret above, so module.secret[each.key]
# always resolves to the secret belonging to this exact lambda.
module "lambda" {
  for_each = { for l in local.lambdas : l.name => l }
  source   = "./modules/lambda"

  name         = each.value.name
  secret_name  = module.secret[each.key].name
  secret_arn   = module.secret[each.key].arn
  auth_type    = each.value.auth_type
  swagger_path = "${path.module}/config/swagger/${each.value.name}.json"
}
