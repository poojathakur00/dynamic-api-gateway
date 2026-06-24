import json
import os
import boto3

secretsmanager = boto3.client("secretsmanager")


def handler(event, context):
    secret_name = os.environ["SECRET_NAME"]

    secret_value = secretsmanager.get_secret_value(SecretId=secret_name)
    secret = json.loads(secret_value["SecretString"])

    base_url = secret.get("base_url")
    api_key = secret.get("api_key")

    # Placeholder — replace with the real call to the backend
    # (Databricks, Snowflake, etc.) using base_url / api_key above.
    return {
        "statusCode": 200,
        "body": json.dumps({
            "message": "proxy reached backend",
            "backend": base_url
        })
    }
