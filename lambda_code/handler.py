import json
import os
import time
import base64
import urllib.request
import urllib.error
import boto3

secretsmanager = boto3.client("secretsmanager")

# Cache Databricks OAuth tokens across warm invocations, keyed by secret name
_token_cache = {}


def get_databricks_token(secret_name, secret):
    """Exchange client_id/client_secret for a short-lived bearer token
    via the Databricks workspace's OIDC token endpoint."""
    cached = _token_cache.get(secret_name)
    if cached and cached[1] > time.time():
        return cached[0]

    workspace_host = secret["host"]  # e.g. "dbc-xxxx.cloud.databricks.com"
    credentials = f"{secret['client_id']}:{secret['client_secret']}"
    basic_auth = base64.b64encode(credentials.encode()).decode()

    req = urllib.request.Request(
        f"https://{workspace_host}/oidc/v1/token",
        data=b"grant_type=client_credentials&scope=all-apis",
        headers={
            "Content-Type": "application/x-www-form-urlencoded",
            "Authorization": f"Basic {basic_auth}",
        },
    )
    with urllib.request.urlopen(req) as resp:
        token_data = json.loads(resp.read())

    token = token_data["access_token"]
    expires_at = time.time() + token_data["expires_in"] - 60  # refresh 60s early
    _token_cache[secret_name] = (token, expires_at)
    return token


def build_auth_headers(secret_name, secret, auth_type):
    if auth_type == "databricks_oauth":
        token = get_databricks_token(secret_name, secret)
        return {"Authorization": f"Bearer {token}"}
    elif auth_type == "api_key":
        return {"Authorization": f"Bearer {secret['api_key']}"}
    else:
        raise ValueError(f"Unknown auth_type: {auth_type}")


def get_backend_base_url(secret, auth_type):
    if auth_type == "databricks_oauth":
        return secret["url"]
    elif auth_type == "api_key":
        return secret["base_url"]
    else:
        raise ValueError(f"Unknown auth_type: {auth_type}")


def handler(event, context):
    secret_name = os.environ["SECRET_NAME"]
    auth_type = os.environ["AUTH_TYPE"]

    secret = json.loads(
        secretsmanager.get_secret_value(SecretId=secret_name)["SecretString"]
    )

    auth_headers = build_auth_headers(secret_name, secret, auth_type)
    backend_url = get_backend_base_url(secret, auth_type).rstrip("/") + event["path"]

    print(f"DEBUG forwarding {event['httpMethod']} {backend_url}")

    req = urllib.request.Request(
        backend_url,
        method=event["httpMethod"],
        data=event["body"].encode() if event.get("body") else None,
        headers={**auth_headers, "Content-Type": "application/json"},
    )

    try:
        with urllib.request.urlopen(req) as resp:
            body = resp.read().decode()
            print(f"DEBUG backend responded {resp.status}: {body}")
            return {"statusCode": resp.status, "body": body}
    except urllib.error.HTTPError as e:
        body = e.read().decode()
        print(f"DEBUG backend HTTPError {e.code}: {body}")
        return {"statusCode": e.code, "body": body}