import os
from typing import Any, Dict, List, Optional

from azure.core.exceptions import HttpResponseError
from azure.search.documents import SearchClient

try:
    from azure.identity import DefaultAzureCredential
except ImportError:
    DefaultAzureCredential = None


def _get_required_env(name: str) -> str:
    value = os.getenv(name)
    if not value:
        raise ValueError(f"Missing environment variable: {name}")
    return value


def _escape_filter_value(value: str) -> str:
    # OData string literal escaping: single quote is doubled
    return value.replace("'", "''")


def _create_search_client() -> SearchClient:
    endpoint = _get_required_env("SEARCH_SERVICE_ENDPOINT")
    index_name = _get_required_env("SEARCH_INDEX_NAME")

    if DefaultAzureCredential is None:
        raise ValueError(
            "azure-identity is not available. Install azure-identity and configure Managed Identity (or dev credentials)."
        )

    credential = DefaultAzureCredential()
    return SearchClient(endpoint=endpoint, index_name=index_name, credential=credential)


def search_chunks(*, query: str, product_id: str, top: int = 5) -> List[Dict[str, Any]]:
    if not query or not query.strip():
        raise ValueError("query is required")
    if not product_id or not product_id.strip():
        raise ValueError("product_id is required")

    # Your index uses 'snippet' as the text field; keep it configurable via env.
    content_field = os.getenv("SEARCH_CONTENT_FIELD", "snippet")
    select_fields = os.getenv("SEARCH_SELECT_FIELDS", "").strip()
    select = [field.strip() for field in select_fields.split(",") if field.strip()] if select_fields else None

    safe_product_id = _escape_filter_value(product_id.strip())
    filter_expression = f"product_id eq '{safe_product_id}'"

    search_client = _create_search_client()

    search_kwargs: Dict[str, Any] = {
        "search_text": query,
        "filter": filter_expression,
        "top": top,
    }
    if select:
        search_kwargs["select"] = select

    try:
        results = search_client.search(**search_kwargs)
    except HttpResponseError as e:
        # If $select contains a field that doesn't exist in the index, retry without select.
        message = str(e)
        if "Parameter name: $select" in message and "Could not find a property named" in message and "select" in search_kwargs:
            search_kwargs.pop("select", None)
            results = search_client.search(**search_kwargs)
        else:
            raise

    items: List[Dict[str, Any]] = []
    for result in results:
        # result behaves like a mapping
        doc: Dict[str, Any] = dict(result)

        text_value: Optional[str] = None
        for candidate in (content_field, "snippet", "content", "chunk", "text"):
            if candidate in doc and doc.get(candidate) is not None:
                text_value = doc.get(candidate)
                break

        items.append(
            {
                "id": doc.get("uid") or doc.get("id"),
                "product_id": doc.get("product_id"),
                "text": text_value,
                "score": doc.get("@search.score"),
                "source": {
                    "blob_url": doc.get("blob_url"),
                    "snippet_parent_id": doc.get("snippet_parent_id"),
                    "metadata_storage_name": doc.get("metadata_storage_name"),
                    "metadata_storage_path": doc.get("metadata_storage_path"),
                    "metadata_storage_uri": doc.get("metadata_storage_uri"),
                },
                "raw": doc,
            }
        )

    return items
