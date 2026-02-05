"""Unit tests for Azure AI Search query construction and error handling."""

from __future__ import annotations

import pytest

import search_client
from azure.core.exceptions import HttpResponseError


def test_escape_filter_value_doubles_quotes() -> None:
    assert search_client._escape_filter_value("abc") == "abc"
    assert search_client._escape_filter_value("a'b") == "a''b"


def test_get_required_env_missing(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.delenv("MISSING_VAR", raising=False)
    with pytest.raises(ValueError, match="Missing environment variable: MISSING_VAR"):
        search_client._get_required_env("MISSING_VAR")


def test_search_chunks_builds_filter_and_maps_results(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv("SEARCH_SERVICE_ENDPOINT", "https://example.search.windows.net")
    monkeypatch.setenv("SEARCH_INDEX_NAME", "idx")
    monkeypatch.setenv("SEARCH_CONTENT_FIELD", "snippet")

    captured: dict = {}

    class FakeSearchClient:
        def search(self, **kwargs):
            captured.update(kwargs)
            return [
                {
                    "uid": "u1",
                    "product_id": "p'1",
                    "snippet": "hello",
                    "@search.score": 1.23,
                }
            ]

    monkeypatch.setattr(search_client, "_create_search_client", lambda: FakeSearchClient())

    items = search_client.search_chunks(query="q", product_id="p'1", top=3)
    assert captured["top"] == 3
    assert captured["filter"] == "product_id eq 'p''1'"
    assert items[0]["id"] == "u1"
    assert items[0]["text"] == "hello"
    assert items[0]["score"] == 1.23


def test_search_chunks_retries_without_select_on_select_error(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv("SEARCH_SERVICE_ENDPOINT", "https://example.search.windows.net")
    monkeypatch.setenv("SEARCH_INDEX_NAME", "idx")
    monkeypatch.setenv("SEARCH_SELECT_FIELDS", "snippet,does_not_exist")

    calls: list[dict] = []

    class FakeSearchClient:
        def __init__(self):
            self.count = 0

        def search(self, **kwargs):
            self.count += 1
            calls.append(dict(kwargs))
            if self.count == 1:
                # The SDK can return a select-related error when a field is missing.
                # The client should retry without `$select` in that case.
                raise HttpResponseError(
                    "Parameter name: $select. Could not find a property named 'does_not_exist' on type 'search.document'."
                )
            return [{"id": "1", "snippet": "ok", "@search.score": 0.1, "product_id": "p1"}]

    monkeypatch.setattr(search_client, "_create_search_client", lambda: FakeSearchClient())

    items = search_client.search_chunks(query="q", product_id="p1", top=5)

    assert len(items) == 1
    assert len(calls) == 2
    assert "select" in calls[0]
    assert "select" not in calls[1]


def test_search_chunks_validates_inputs() -> None:
    with pytest.raises(ValueError):
        search_client.search_chunks(query="", product_id="p1", top=5)
    with pytest.raises(ValueError):
        search_client.search_chunks(query="q", product_id="  ", top=5)
