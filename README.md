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

1. `config/lambdas.yaml` lists every proxy: a `name`, a `secret_name`, and
   an `auth_type` (`api_key` or `databricks_oauth`).
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
   JSON value for each secret name printed in the `secret_names` output.
   The expected shape depends on that proxy's `auth_type` — see below.
5. At runtime, `handler.py` reads the `SECRET_NAME` and `AUTH_TYPE` env vars,
   fetches the secret, and dispatches to the matching auth strategy before
   forwarding the request to the real backend.

## Auth types

One shared `handler.py` supports multiple backends by branching on `auth_type`.
Each type expects a different shape inside the secret's JSON value:

**`api_key`** — static bearer token:
```json
{"base_url": "https://your-backend-url", "api_key": "your-key"}
```

**`databricks_oauth`** — OAuth2 client-credentials flow against a Databricks
workspace. The Lambda exchanges `client_id`/`client_secret` for a short-lived
token (cached across warm invocations) before calling the app:
```json
{
  "host": "dbc-xxxx.cloud.databricks.com",
  "url": "https://your-app-url.databricksapps.com",
  "client_id": "...",
  "client_secret": "..."
}
```

Adding a third auth type means adding one more branch in `build_auth_headers`
/ `get_backend_base_url` in `handler.py` — every existing proxy is unaffected.

## Adding a new proxy

1. Add an entry to `config/lambdas.yaml`:
```yaml
   - name: databricks-proxy
     secret_name: databricks/prod
     auth_type: databricks_oauth
```
2. Add `config/swagger/databricks-proxy.json` — plain OpenAPI, just `paths`.
   The filename must exactly match the `name` field above.
3. `terraform apply`.
4. Fill in the secret value in the AWS console (name comes from the
   `secret_names` output) — shape depends on `auth_type`, see above.

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
- **API Gateway endpoints are fully unauthenticated** — no API key, no IAM
  auth, no Cognito/Lambda authorizer. Anyone with the URL can invoke the
  proxy. Acceptable while testing; needs an API Gateway usage plan / API key
  or an authorizer before this sees real traffic.
- **`handler.py` has temporary `DEBUG` print statements** in the request path
  (forwarded URL, backend response) added for troubleshooting the Databricks
  integration. Safe to leave (just extra CloudWatch noise) or strip out once
  things are stable.
- **One API Gateway per Lambda** (1:1), bundled in the same module — this
  was a deliberate choice since they're always created together. If you
  ever need a shared gateway across multiple lambdas, that assumption
  would need revisiting.
- `lambdas.yaml` is a single shared file — fine for a couple of teams, but
  if many independent teams start PRing into it, consider splitting into
  `config/lambdas/<team>.yaml` and using `fileset()` to glob them instead.