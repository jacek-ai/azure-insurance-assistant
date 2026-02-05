"""Unit tests for the OpenAPI tool builder used by the agent."""

from __future__ import annotations

import json
from pathlib import Path

from tools.function_openapi_tool import build_insurance_functions_tool


def test_build_insurance_functions_tool_overrides_servers(tmp_path: Path) -> None:
    # Ensure the tool normalizes/overrides the server URL for a deployed Functions app.
    spec = {
        "openapi": "3.0.0",
        "info": {"title": "x", "version": "1"},
        "servers": [{"url": "https://placeholder"}],
        "paths": {},
    }
    spec_path = tmp_path / "spec.json"
    spec_path.write_text(json.dumps(spec), encoding="utf-8")

    tool = build_insurance_functions_tool(
        function_base_url="https://my-func.azurewebsites.net/",
        function_connection_id="conn123",
        openapi_spec_path=spec_path,
    )

    returned_spec = tool["openapi"]["spec"]
    assert returned_spec["servers"][0]["url"] == "https://my-func.azurewebsites.net"
    assert tool["openapi"]["auth"]["security_scheme"]["project_connection_id"] == "conn123"
