"""Unit tests for product filtering and validation logic."""

from __future__ import annotations

from datetime import date

import pytest

import products_client


def test_parse_iso_date_valid() -> None:
    assert products_client._parse_iso_date("2024-01-31") == date(2024, 1, 31)


@pytest.mark.parametrize(
    "value",
    [
        "2024/01/31",
        "31-01-2024",
        "not-a-date",
        "",
    ],
)
def test_parse_iso_date_invalid(value: str) -> None:
    with pytest.raises(ValueError):
        products_client._parse_iso_date(value)


def test_is_product_active_on_requires_date_from() -> None:
    product = {"product_id": "p1"}
    assert products_client._is_product_active_on(product, date(2024, 1, 1)) is False


def test_is_product_active_on_open_ended_date_to() -> None:
    product = {"date_from": "2024-01-01", "date_to": ""}
    assert products_client._is_product_active_on(product, date(2023, 12, 31)) is False
    assert products_client._is_product_active_on(product, date(2024, 1, 1)) is True
    assert products_client._is_product_active_on(product, date(2025, 1, 1)) is True


def test_is_product_active_on_bounded_range() -> None:
    product = {"date_from": "2024-01-01", "date_to": "2024-06-30"}
    assert products_client._is_product_active_on(product, date(2023, 12, 31)) is False
    assert products_client._is_product_active_on(product, date(2024, 1, 1)) is True
    assert products_client._is_product_active_on(product, date(2024, 6, 30)) is True
    assert products_client._is_product_active_on(product, date(2024, 7, 1)) is False


def test_list_products_filters_by_type_and_date(monkeypatch: pytest.MonkeyPatch) -> None:
    payload = {
        "Products": [
            {
                "product_id": "a",
                "product_type": "Home",
                "date_from": "2024-01-01",
                "date_to": "",
            },
            {
                "product_id": "b",
                "product_type": "Auto",
                "date_from": "2024-01-01",
                "date_to": "2024-02-01",
            },
            {
                "product_id": "c",
                "product_type": "home",
                "date_from": "2023-01-01",
                "date_to": "2023-12-31",
            },
        ]
    }

    monkeypatch.setattr(products_client, "_download_products_json", lambda: payload)

    # Product type matching is case-insensitive.
    home = products_client.list_products(product_type="HOME")
    assert [p["product_id"] for p in home] == ["a", "c"]

    # Date filtering applies to the `as_of_date` argument.
    as_of = products_client.list_products(product_type="home", as_of_date="2024-01-15")
    assert [p["product_id"] for p in as_of] == ["a"]


def test_list_products_invalid_payload(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setattr(products_client, "_download_products_json", lambda: {"Products": "nope"})
    with pytest.raises(RuntimeError, match="Products"):
        products_client.list_products()
