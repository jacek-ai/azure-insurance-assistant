"""Product catalog client.

Downloads the product list from Blob Storage and applies simple filters.
Authentication is done via `DefaultAzureCredential` (Managed Identity in Azure).
"""

import json
import os
from datetime import date
from typing import Any, Dict, List, Optional

from azure.identity import DefaultAzureCredential
from azure.storage.blob import BlobServiceClient


def _parse_iso_date(value: str) -> date:
    """Parse ISO date in the form YYYY-MM-DD.

    Raises:
        ValueError: If the input is not a valid ISO date.
    """
    return date.fromisoformat(value)


def _is_product_active_on(product: Dict[str, Any], as_of: date) -> bool:
    """Return True if a product is active on the given date."""
    date_from_raw = (product.get("date_from") or "").strip()
    date_to_raw = (product.get("date_to") or "").strip()

    if not date_from_raw:
        return False

    start = _parse_iso_date(date_from_raw)

    if date_to_raw:
        end = _parse_iso_date(date_to_raw)
        return start <= as_of <= end

    return start <= as_of


def _download_products_json() -> Dict[str, Any]:
    """Download and parse the products JSON blob.

    Expected env:
        - BLOB_ACCOUNT_URL: https://<account>.blob.core.windows.net
        - PRODUCTS_CONTAINER_NAME (optional)
        - PRODUCTS_BLOB_NAME (optional)
    """
    account_url = os.getenv("BLOB_ACCOUNT_URL")

    container_name = os.getenv("PRODUCTS_CONTAINER_NAME", "products")
    blob_name = os.getenv("PRODUCTS_BLOB_NAME", "products.json")

    if account_url:
        credential = DefaultAzureCredential()
        blob_service = BlobServiceClient(account_url=account_url, credential=credential)
    else:
        raise RuntimeError(
            "Missing blob configuration. Set BLOB_ACCOUNT_URL (Managed Identity authentication)."
        )

    blob_client = blob_service.get_blob_client(container=container_name, blob=blob_name)
    content = blob_client.download_blob().readall()

    try:
        return json.loads(content)
    except json.JSONDecodeError as e:
        raise RuntimeError(f"Invalid JSON in blob {container_name}/{blob_name}: {e}")


def list_products(
    *,
    product_type: Optional[str] = None,
    as_of_date: Optional[str] = None,
) -> List[Dict[str, Any]]:
    """List products, optionally filtering by type and/or effective date.

    Args:
        product_type: Exact match (case-insensitive).
        as_of_date: ISO date (YYYY-MM-DD). Returns products active on that date.
    """
    payload = _download_products_json()

    products = payload.get("Products")
    if not isinstance(products, list):
        raise RuntimeError("Invalid products payload: missing 'Products' array")

    filtered = products

    if product_type is not None and str(product_type).strip():
        needle = str(product_type).strip().casefold()
        filtered = [
            p
            for p in filtered
            if isinstance(p, dict)
            and str(p.get("product_type") or "").strip().casefold() == needle
        ]

    if as_of_date is not None and str(as_of_date).strip():
        as_of = _parse_iso_date(str(as_of_date).strip())
        filtered = [p for p in filtered if isinstance(p, dict) and _is_product_active_on(p, as_of)]

    return filtered
