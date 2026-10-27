"""Validate captured JSON requests/responses against the unchanged OpenAPI.

Usage: python tests/contract/validate_http_captures.py /private/captures.json
Each capture has operationId, status, response, and optional request/validRequest.
Fixtures and credentials stay outside Git. Requires PyYAML and jsonschema.
"""
import json
import sys
from pathlib import Path

import yaml
from jsonschema import Draft202012Validator

root = Path(__file__).resolve().parents[2]
api = yaml.safe_load((root / "openapi.yaml").read_text(encoding="utf-8"))
operations = {
    operation["operationId"]: operation
    for path in api["paths"].values()
    for operation in path.values()
    if isinstance(operation, dict) and "operationId" in operation
}


def resolve_response(response):
    if "$ref" not in response:
        return response
    value = api
    for key in response["$ref"].removeprefix("#/").split("/"):
        value = value[key.replace("~1", "/").replace("~0", "~")]
    return value


def validate(schema, instance):
    # Keep components at the document root so local schema references resolve.
    Draft202012Validator({**api, **schema}).validate(instance)


captures = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
if not captures:
    raise ValueError("No HTTP captures supplied")
for capture in captures:
    operation = operations[capture["operationId"]]
    response = resolve_response(operation["responses"][str(capture["status"])])
    validate(response["content"]["application/json"]["schema"], capture["response"])
    if "request" in capture:
        request_schema = operation["requestBody"]["content"]["application/json"]["schema"]
        if capture.get("validRequest", True):
            validate(request_schema, capture["request"])
        elif Draft202012Validator({**api, **request_schema}).is_valid(capture["request"]):
            raise ValueError("Invalid-request fixture was accepted by the contract")
print(f"OpenAPI real HTTP captures validated: {len(captures)}")
