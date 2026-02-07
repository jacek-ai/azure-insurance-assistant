"""Product catalog client.

Downloads the product list from Blob Storage and applies lightweight filtering.

This module is used by the agent tool `list_products`. The user may provide a
free-text hint like "Produkt Wojażer 2025" or "Twoje auto 26-01-2025".
The implementation attempts to:
- extract a date from the hint (if present)
- fuzzy-match the remaining text against the product catalog

Authentication is done via `DefaultAzureCredential` (Managed Identity in Azure).
"""

import json
import os
import re
import unicodedata
from datetime import date
from difflib import SequenceMatcher
from typing import Any, Dict, Iterable, List, Optional, Tuple

from azure.identity import DefaultAzureCredential
from azure.storage.blob import BlobServiceClient


def _parse_iso_date(value: str) -> date:
    """Parse ISO date in the form YYYY-MM-DD.

    Raises:
        ValueError: If the input is not a valid ISO date.
    """
    return date.fromisoformat(value)


def _normalize_text(value: str) -> str:
    """Normalize free-form user text for matching.

    - lowercases
    - removes diacritics
    - removes most punctuation
    - collapses whitespace
    """
    if value is None:
        return ""

    text = str(value).strip().casefold()
    text = unicodedata.normalize("NFKD", text)
    text = "".join(ch for ch in text if not unicodedata.combining(ch))
    text = re.sub(r"[^0-9a-zA-Z\s]+", " ", text)
    text = re.sub(r"\s+", " ", text).strip()
    return text


def _tokenize(value: str) -> List[str]:
    """Tokenize normalized text, removing common filler words."""
    stopwords = {
        "ubezpieczenie",
        "ubezpieczenia",
        "produkt",
        "twoje",
        "twoj",
        "polisa",
        "polisy",
        "dla",
        "w",
        "na",
        "i",
        "oraz",
    }
    tokens = [t for t in _normalize_text(value).split(" ") if t and t not in stopwords]
    return tokens


def _try_parse_date_from_text(text: str) -> Tuple[Optional[date], str]:
    """Best-effort parse a date from free-form text.

    Supported patterns (first match wins):
      - YYYY-MM-DD
      - DD-MM-YYYY
      - DD/MM/YYYY
      - DD.MM.YYYY
      - standalone year (YYYY) -> uses mid-year (YYYY-07-01)

    Returns:
      (parsed_date_or_none, text_without_the_date_fragment)
    """
    if not text:
        return None, ""

    raw = str(text)

    # 1) ISO
    m = re.search(r"\b(?P<y>\d{4})-(?P<m>\d{2})-(?P<d>\d{2})\b", raw)
    if m:
        try:
            parsed = date(int(m.group("y")), int(m.group("m")), int(m.group("d")))
            cleaned = (raw[: m.start()] + " " + raw[m.end() :]).strip()
            return parsed, cleaned
        except ValueError:
            pass

    # 2) DD[./-]MM[./-]YYYY
    m = re.search(r"\b(?P<d>\d{1,2})[./-](?P<m>\d{1,2})[./-](?P<y>\d{4})\b", raw)
    if m:
        try:
            parsed = date(int(m.group("y")), int(m.group("m")), int(m.group("d")))
            cleaned = (raw[: m.start()] + " " + raw[m.end() :]).strip()
            return parsed, cleaned
        except ValueError:
            pass

    # 3) standalone year (e.g. "Wojażer 2025")
    m = re.search(r"\b(?P<y>19\d{2}|20\d{2})\b", raw)
    if m:
        year = int(m.group("y"))
        if 1900 <= year <= 2100:
            cleaned = (raw[: m.start()] + " " + raw[m.end() :]).strip()
            return date(year, 7, 1), cleaned

    return None, raw


def _iter_product_text_fields(product: Dict[str, Any]) -> Iterable[str]:
    for k in ("product_name", "product_type", "product_description"):
        v = product.get(k)
        if isinstance(v, str) and v.strip():
            yield v


def _match_score(query: str, product: Dict[str, Any]) -> float:
    """Compute a lightweight fuzzy match score for ranking results."""
    q_norm = _normalize_text(query)
    if not q_norm:
        return 0.0

    q_tokens = set(_tokenize(q_norm))

    best_seq = 0.0
    best_sub = 0.0
    all_tokens: set[str] = set()

    for field in _iter_product_text_fields(product):
        f_norm = _normalize_text(field)
        if not f_norm:
            continue
        best_seq = max(best_seq, SequenceMatcher(None, q_norm, f_norm).ratio())
        if q_norm in f_norm:
            best_sub = 1.0
        all_tokens |= set(_tokenize(f_norm))

    token_overlap = 0.0
    if q_tokens:
        token_overlap = len(q_tokens & all_tokens) / len(q_tokens)

    # Weighted score. Keep it simple, deterministic, and dependency-free.
    return (0.55 * best_seq) + (0.35 * token_overlap) + (0.10 * best_sub)


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
    product: Optional[str] = None,
    product_type: Optional[str] = None,
    as_of_date: Optional[str] = None,
) -> List[Dict[str, Any]]:
    """List products, optionally filtering by hint text and/or effective date.

    Args:
        product: Free-form hint, e.g. "Wojażer 2025" or "Auto 26-01-2025".
            The method extracts a date (if present) and fuzzy-matches the
            remaining text against product_name/product_type/description.
        product_type: Backward-compatible exact match filter (case-insensitive).
            If `product` is provided, this value is treated as an additional hint.
        as_of_date: ISO date (YYYY-MM-DD). Returns products active on that date.
    """
    payload = _download_products_json()

    products = payload.get("Products")
    if not isinstance(products, list):
        raise RuntimeError("Invalid products payload: missing 'Products' array")

    filtered: List[Dict[str, Any]] = [p for p in products if isinstance(p, dict)]

    # Resolve effective date.
    derived_date: Optional[date] = None
    derived_hint_text: Optional[str] = None

    if product is not None and str(product).strip():
        derived_date, derived_hint_text = _try_parse_date_from_text(str(product))

    effective_date_raw = None
    if as_of_date is not None and str(as_of_date).strip():
        effective_date_raw = str(as_of_date).strip()
    elif derived_date is not None:
        # Derived from free-text hint.
        effective_date_raw = derived_date.isoformat()

    if effective_date_raw is not None:
        as_of = _parse_iso_date(effective_date_raw)
        filtered = [p for p in filtered if _is_product_active_on(p, as_of)]

    # Backward-compatible type filter.
    if (product is None or not str(product).strip()) and product_type is not None and str(product_type).strip():
        needle = str(product_type).strip().casefold()
        filtered = [
            p
            for p in filtered
            if str(p.get("product_type") or "").strip().casefold() == needle
        ]
        return filtered

    # Fuzzy match by free-text hint (preferred).
    hint_parts: List[str] = []
    if derived_hint_text is not None and derived_hint_text.strip():
        hint_parts.append(derived_hint_text)
    elif product is not None and str(product).strip():
        hint_parts.append(str(product).strip())
    if product_type is not None and str(product_type).strip():
        hint_parts.append(str(product_type).strip())

    hint = " ".join(hint_parts).strip()
    if not hint:
        return filtered

    scored = [
        (p, _match_score(hint, p))
        for p in filtered
    ]

    # Deterministic ordering: score desc, then name/version/id.
    scored.sort(
        key=lambda it: (
            -it[1],
            str(it[0].get("product_name") or ""),
            str(it[0].get("product_version_no") or ""),
            str(it[0].get("product_id") or ""),
        )
    )

    return [p for (p, _s) in scored]
