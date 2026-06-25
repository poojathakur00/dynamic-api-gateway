# terraform-lambda-proxy

Config-driven Lambda proxies. Add an entry to `config/lambdas.yaml` and a
matching swagger file in `config/swagger/`, run `terraform apply`, and you
get a Lambda + API Gateway for that backend — no HCL knowledge required to
add a new proxy.

## Layout

```
.
├── main.tf                  # reads config/lambdas.yaml, calls both modules below
├── outputs.tf
├── variables.tf / providers.tf / versions.tf
├── config/
│   ├── lambdas.yaml          # the master list: one entry per proxy
│   └── swagger/
│       ├── <name-of-the-lambda>.json     # clean OpenAPI, no AWS extensions
├── lambda_code/
│   └── handler.py            # ONE shared codebase for every proxy (Python 3.12)
├── modules/
│   ├── lambda/                # Lambda + IAM role/policy + API Gateway, per proxy
│   └── secrets_manager/       # creates an empty secret "shell", per proxy
└── builds/                    # auto-generated zips (gitignored) — created at apply time
```

## How it fits together

1. `config/lambdas.yaml` lists every proxy: a `name` and a `secret_name`.
2. `main.tf` loops over that list with `for_each`, calling `module.secret`
   and `module.lambda` once per entry — both keyed identically by `name`,
   so `module.secret[each.key]` always pairs with the right lambda.
3. `modules/lambda` zips the **same** `lambda_code/handler.py` for every
   instance, creates the Lambda, reads the matching `config/swagger/<name>.json`,
   dynamically injects the AWS API Gateway integration into every path/method
   (devs never write AWS-specific swagger), and publishes a live API Gateway
   stage pointed at that Lambda.
4. `modules/secrets_manager` only creates the secret *container* — no value.
   After `apply`, a human goes into Secrets Manager and fills in the real
   JSON value (e.g. `{"base_url": "...", "api_key": "..."}`) for each secret
   name printed in the `secret_names` output.
5. At runtime, `handler.py` reads the `SECRET_NAME` env var, calls
   `GetSecretValue`, and uses the result to call the real backend.

## Adding a new proxy

1. Add an entry to `config/lambdas.yaml`:
   ```yaml
   - name: databricks-proxy
     secret_name: databricks/prod
   ```
2. Add `config/swagger/databricks-proxy.json` — plain OpenAPI, just `paths`.
3. `terraform apply`.
4. Fill in the secret value in the AWS console (name comes from the
   `secret_names` output).

No other code changes needed — same shared `handler.py`, same modules.

## Prerequisites

- Terraform >= 1.5
- AWS credentials configured (env vars, `~/.aws/credentials`, or SSO)
- Python 3.12 runtime is set on every Lambda (matches `lambda_code/handler.py`)

## Commands

```bash
terraform init
terraform plan
terraform apply
```

After apply, check the outputs:

```bash
terraform output api_urls
terraform output secret_names
```

## Known gaps / things to decide next

- **No guardrail** if a secret value is never filled in — the Lambda deploys
  fine but fails at first invocation. Fine for now; revisit if this needs
  monitoring/alerting before go-live.
- **One API Gateway per Lambda** (1:1), bundled in the same module — this
  was a deliberate choice since they're always created together. If you
  ever need a shared gateway across multiple lambdas, that assumption
  would need revisiting.
- `lambdas.yaml` is a single shared file — fine for a couple of teams, but
  if many independent teams start PRing into it, consider splitting into
  `config/lambdas/<team>.yaml` and using `fileset()` to glob them instead.
