"""HTTP-level tests for Azure Functions endpoints.

These tests exercise the request/response shape and input validation logic of the
Functions entrypoints without running an actual Functions host.
"""

from __future__ import annotations

import json

import pytest

import function_app


class FakeReq:
    """Minimal request stub compatible with the Functions entrypoints under test."""

    def __init__(self, payload=None, raises: Exception | None = None):
        self._payload = payload
        self._raises = raises

    def get_json(self):
        """Return the request JSON payload or raise the configured exception."""
        if self._raises is not None:
            raise self._raises
        return self._payload


def _body_json(resp) -> dict:
    """Decode an Azure Functions HTTP response body as JSON."""
    raw = resp.get_body()
    if isinstance(raw, (bytes, bytearray)):
        raw = raw.decode("utf-8")
    return json.loads(raw)


def test_search_chunks_endpoint_invalid_json(monkeypatch: pytest.MonkeyPatch) -> None:
    resp = function_app.search_chunks_endpoint(FakeReq(raises=ValueError("bad")))
    body = _body_json(resp)
    assert resp.status_code == 200
    assert body["chunks"] == []
    assert "Invalid JSON" in body["error"]


def test_search_chunks_endpoint_requires_query_and_product_id() -> None:
    resp = function_app.search_chunks_endpoint(FakeReq({}))
    body = _body_json(resp)
    assert body["error"] == "'query' is required"

    resp2 = function_app.search_chunks_endpoint(FakeReq({"query": "q"}))
    body2 = _body_json(resp2)
    assert body2["error"] == "'product_id' is required"


def test_search_chunks_endpoint_validates_top() -> None:
    resp = function_app.search_chunks_endpoint(FakeReq({"query": "q", "product_id": "p", "top": "abc"}))
    assert _body_json(resp)["error"] == "'top' must be an integer"

    resp2 = function_app.search_chunks_endpoint(FakeReq({"query": "q", "product_id": "p", "top": 0}))
    assert _body_json(resp2)["error"] == "'top' must be between 1 and 50"


def test_search_chunks_endpoint_happy_path(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setattr(function_app, "search_chunks", lambda **kwargs: [{"id": "1"}])

    resp = function_app.search_chunks_endpoint(FakeReq({"query": "q", "product_id": "p", "top": 2}))
    body = _body_json(resp)
    assert body["error"] is None
    assert body["chunks"] == [{"id": "1"}]


def test_products_endpoint_happy_path(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setattr(function_app, "list_products", lambda **kwargs: [{"product_id": "a"}])

    resp = function_app.products_endpoint(FakeReq({"product_type": "home", "date": "2024-01-01"}))
    body = _body_json(resp)
    assert body["error"] is None
    assert body["products"] == [{"product_id": "a"}]


def test_products_endpoint_validation_error(monkeypatch: pytest.MonkeyPatch) -> None:
    def _boom(**kwargs):
        raise ValueError("bad date")

    monkeypatch.setattr(function_app, "list_products", _boom)

    resp = function_app.products_endpoint(FakeReq({"date": "nope"}))
    body = _body_json(resp)
    assert body["products"] == []
    assert body["error"].startswith("Invalid input:")
