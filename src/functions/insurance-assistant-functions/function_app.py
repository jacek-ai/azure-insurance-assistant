"""HTTP endpoints exposed as Azure Functions for the agent tool calls.

Design note: endpoints return HTTP 200 for both success and failure, with an
`error` field in the JSON body. This keeps the OpenAPI tool integration simple.
"""

import json

import azure.functions as func

from search_client import search_chunks
from products_client import list_products

app = func.FunctionApp(http_auth_level=func.AuthLevel.FUNCTION)


@app.route(route="search_chunks", methods=["POST"])
def search_chunks_endpoint(req: func.HttpRequest) -> func.HttpResponse:
    """Search RAG chunks filtered by `product_id`.

    Expects JSON body: { query: str, product_id: str, top?: int }.
    """

    def ok_json(payload: dict) -> func.HttpResponse:
        """Return a JSON response (always HTTP 200)."""
        return func.HttpResponse(
            body=json.dumps(payload, ensure_ascii=False),
            mimetype="application/json",
            status_code=200,
        )

    try:
        body = req.get_json()
    except ValueError:
        # Azure Functions raises ValueError when the body is not valid JSON.
        return ok_json({"chunks": [], "error": "Invalid JSON body"})

    query = (body or {}).get("query")
    product_id = (body or {}).get("product_id")
    top = (body or {}).get("top", 5)

    if not isinstance(query, str) or not query.strip():
        return ok_json({"chunks": [], "error": "'query' is required"})
    if not isinstance(product_id, str) or not product_id.strip():
        return ok_json({"chunks": [], "error": "'product_id' is required"})

    try:
        top_int = int(top)
    except (TypeError, ValueError):
        return ok_json({"chunks": [], "error": "'top' must be an integer"})

    if top_int < 1 or top_int > 50:
        return ok_json({"chunks": [], "error": "'top' must be between 1 and 50"})

    try:
        chunks = search_chunks(query=query, product_id=product_id, top=top_int)
    except Exception as e:
        # Keep error messages short; details belong in logs/telemetry.
        return ok_json({"chunks": [], "error": f"Search failed: {e}"})

    return ok_json({"chunks": chunks, "error": None})


@app.route(route="products", methods=["POST"])
def products_endpoint(req: func.HttpRequest) -> func.HttpResponse:
    """List products from the catalog (optionally filtered).

    Accepts optional JSON body: { product_type?: str, date?: YYYY-MM-DD }.
    """

    def ok_json(payload: dict) -> func.HttpResponse:
        """Return a JSON response (always HTTP 200)."""
        return func.HttpResponse(
            body=json.dumps(payload, ensure_ascii=False),
            mimetype="application/json",
            status_code=200,
        )

    try:
        body = req.get_json()
    except ValueError:
        # Treat invalid JSON as "no filters" for this endpoint.
        body = {}

    product_type = (body or {}).get("product_type")
    as_of_date = (body or {}).get("date")

    try:
        products = list_products(product_type=product_type, as_of_date=as_of_date)
    except ValueError as e:
        return ok_json({"products": [], "error": f"Invalid input: {e}"})
    except Exception as e:
        return ok_json({"products": [], "error": f"Products lookup failed: {e}"})

    return ok_json({"products": products, "error": None})
