"""Contract tests for the shipped OpenAPI specification.

The agent tooling relies on the OpenAPI document under `src/agent/assets`.
These tests verify the most important paths and security scheme are present.
"""

from __future__ import annotations

import json
from pathlib import Path


def _load_spec() -> dict:
    """Load the OpenAPI JSON spec shipped with the agent assets."""
    repo_root = Path(__file__).resolve().parents[1]
    spec_path = repo_root / "src" / "agent" / "assets" / "function_openapi.json"
    return json.loads(spec_path.read_text(encoding="utf-8"))


def test_openapi_has_expected_paths_and_methods() -> None:
    spec = _load_spec()
    paths = spec.get("paths") or {}

    assert "/api/products" in paths
    assert "post" in (paths["/api/products"] or {})

    assert "/api/search_chunks" in paths
    assert "post" in (paths["/api/search_chunks"] or {})


def test_openapi_security_scheme_function_key() -> None:
    spec = _load_spec()

    scheme = (
        spec.get("components", {})
        .get("securitySchemes", {})
        .get("functionKey", {})
    )

    assert scheme.get("type") == "apiKey"
    assert scheme.get("in") == "header"
    assert scheme.get("name") == "x-functions-key"
