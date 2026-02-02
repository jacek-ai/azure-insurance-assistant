import json
from pathlib import Path


def build_insurance_functions_tool(*, function_base_url: str, function_connection_id: str, openapi_spec_path: str | Path) -> dict:
    """Build an OpenAPI tool configuration for calling Azure Functions over HTTP.

    Args:
        function_base_url: Base URL for the Function App (e.g. https://<app>.azurewebsites.net).
        function_connection_id: Foundry Project Connection id that stores the Function Key (x-functions-key).
        openapi_spec_path: Path to the OpenAPI JSON spec file.

    Returns:
        Tool dict to be passed to PromptAgentDefinition(tools=[...]).
    """

    openapi_spec_path = Path(openapi_spec_path)
    with openapi_spec_path.open("r", encoding="utf-8") as file_handle:
        function_openapi_spec = json.load(file_handle)

    # Override the placeholder server URL at runtime
    function_openapi_spec["servers"] = [{"url": function_base_url.rstrip("/")}]

    return {
        "type": "openapi",
        "openapi": {
            "name": "insurance_functions",
            "spec": function_openapi_spec,
            "auth": {
                "type": "project_connection",
                "security_scheme": {
                    "project_connection_id": function_connection_id,
                },
            },
        },
    }
