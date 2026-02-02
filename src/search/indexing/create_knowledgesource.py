"""
Azure AI Search Knowledge Source Provisioning

Creates and configures Azure AI Search resources (datasources, indexes, skillsets, indexers)
via REST API with support for custom field mappings.

Features:
- Creates Knowledge Source from JSON template
- Adds custom fields to existing indexe
- Adds field mappings to indexer
- Updates skillset projections with new field mappings
- Supports API key and Azure AD authentication
- Automatic retry logic for transient failures

Usage:
    Set required environment variables in .env:
    - SEARCH_SERVICE_ENDPOINT
    - SEARCH_API_VERSION
    - AI_SERVICE_ENDPOINT
    - AI_MODEL_DEPLOYMENT
    - STORAGE_CONNECTION_STRING
    
    Then run: python create_knowledgesource.py

Authentication:
- API Key: SearchAuth(api_key="your-key")
- Azure AD: SearchAuth(use_aad=True)
"""
from __future__ import annotations

import json
import os
import time
from dataclasses import dataclass
from pathlib import Path
from string import Template
from typing import Any, Dict, Optional, Union
from dotenv import load_dotenv

import requests

try:
    from azure.identity import DefaultAzureCredential
except ImportError:
    DefaultAzureCredential = None  # type: ignore

JsonDict = Dict[str, Any]

@dataclass
class SearchAuth:
    """
    Authentication configuration for Azure AI Search.
    
    Supports two authentication methods (mutually exclusive):
    - API Key: Set api_key with admin key (uses 'api-key' header)
    - Azure AD: Set use_aad=True to use bearer token via DefaultAzureCredential
                (Managed Identity or Service Principal)
    """
    api_key: Optional[str] = None
    use_aad: bool = False  # jeśli True, pobierze token i użyje Authorization: Bearer ...

    # Scope dla Azure AI Search (AAD)
    aad_scope: str = "https://search.azure.com/.default"

class AzureSearchRestClient:
    """
    REST client for Azure AI Search with authentication and retry logic.
    """
    def __init__(
        self,
        base_url: str,
        api_version: str,
        auth: SearchAuth,
        *,
        timeout_s: int = 60,
        retries: int = 3,
        retry_backoff_s: float = 0.8,
    ):
        """
        Initialize Azure Search REST client.
        
        Args:
            base_url: Service endpoint (e.g., https://<service>.search.windows.net)
            api_version: REST API version (e.g., 2025-09-01)
            auth: Authentication configuration
            timeout_s: Request timeout in seconds
            retries: Max retry attempts for transient errors
            retry_backoff_s: Base backoff time for retries
            
        Raises:
            RuntimeError: If use_aad=True but azure-identity not installed
        """
        self.base_url = base_url.rstrip("/")
        self.api_version = api_version
        self.auth = auth
        self.timeout_s = timeout_s
        self.retries = retries
        self.retry_backoff_s = retry_backoff_s

        if self.auth.use_aad and DefaultAzureCredential is None:
            raise RuntimeError(
                "azure-identity not installed. Run: pip install azure-identity "
                "or use auth.api_key instead."
            )

        self._credential = DefaultAzureCredential() if self.auth.use_aad else None
        self._cached_token: Optional[str] = None
        self._cached_token_expires_on: Optional[int] = None

    # --------- Token handling (AAD) ---------

    def _get_bearer_token(self) -> str:
        assert self._credential is not None

        now = int(time.time())
        if self._cached_token and self._cached_token_expires_on and now < (self._cached_token_expires_on - 60):
            return self._cached_token

        token = self._credential.get_token(self.auth.aad_scope)
        self._cached_token = token.token
        self._cached_token_expires_on = token.expires_on
        return token.token

    # --------- Template loading ---------

    @staticmethod
    def _load_json_template(template_path: Union[str, Path], params: Dict[str, Any]) -> JsonDict:
        """
        Load JSON template with variable substitution.
        
        Supports placeholders like ${var} in JSON files.
        Example: "connectionString": "${storageConnectionString}"
        
        Args:
            template_path: Path to JSON template file
            params: Dictionary of substitution parameters
            
        Returns:
            Parsed JSON as dictionary with substituted values
        """
        raw = Path(template_path).read_text(encoding="utf-8")
        rendered = Template(raw).safe_substitute({k: str(v) for k, v in params.items()})

        return json.loads(rendered)

    # --------- One generic REST method ---------

    def request(
        self,
        method: str,
        path: str,
        *,
        # parametry do query string (poza api-version)
        query: Optional[Dict[str, Any]] = None,
        # body jako dict albo jako ścieżka do template json + params
        json_body: Optional[JsonDict] = None,
        json_template_path: Optional[Union[str, Path]] = None,
        template_params: Optional[Dict[str, Any]] = None,
        # dodatkowe nagłówki
        headers: Optional[Dict[str, str]] = None,
        # zwróć surowy response zamiast JSON
        return_response: bool = False,
    ) -> Any:
        """
        Execute authenticated HTTP request to Azure AI Search REST API.
        
        Args:
            method: HTTP method (GET, POST, PUT, PATCH, DELETE)
            path: API endpoint (e.g., "/datasources" or "/indexers/my-indexer/status")
            query: Additional query string parameters
            json_body: Request body as dictionary
            json_template_path: Path to JSON template file
            template_params: Parameters for template substitution
            headers: Additional HTTP headers
            return_response: Return raw Response instead of parsed JSON
            
        Returns:
            Parsed JSON response or Response object if return_response=True
        """
        method = method.upper()

        path = "/" + path.lstrip("/")

        params = {"api-version": self.api_version}
        if query:
            params.update(query)

        url = f"{self.base_url}{path}"

        # prepare body
        body = None
        if json_template_path is not None:
            body = self._load_json_template(json_template_path, template_params or {})
        elif json_body is not None:
            body = json_body

        # prepare headers
        req_headers: Dict[str, str] = {
            "Content-Type": "application/json",
            "Accept": "application/json",
        }
        if headers:
            req_headers.update(headers)

        if self.auth.api_key:
            req_headers["api-key"] = self.auth.api_key
        elif self.auth.use_aad:
            req_headers["Authorization"] = f"Bearer {self._get_bearer_token()}"
        else:
            raise RuntimeError("No authentication configured: set api_key or use_aad=True.")
        
        print(f"{method} {url}")
        print(f"params: {params}")
        print(f"headers: {req_headers}")
        print(f"body: {json.dumps(body, indent=2, ensure_ascii=False)}")

        # Retry logic for errors (429 rate limiting, 5xx server errors)
        last_exc = None
        for attempt in range(1, self.retries + 1):
            try:
                resp = requests.request(
                    method=method,
                    url=url,
                    params=params,
                    headers=req_headers,
                    json=body,
                    timeout=self.timeout_s,
                )

                # Try again for retryable status codes
                if resp.status_code in (429, 500, 502, 503, 504) and attempt < self.retries:
                    time.sleep(self.retry_backoff_s * attempt)
                    continue

                # errror handling
                if not (200 <= resp.status_code < 300):
                    raise RuntimeError(
                        f"HTTP {resp.status_code} {resp.reason} for {method} {url}\n"
                        f"Response body:\n{resp.text}"
                    )

                if return_response:
                    return resp

                # Some operations may return empty body
                if not resp.text.strip():
                    return None
                return resp.json()

            except Exception as exc:
                last_exc = exc
                if attempt < self.retries:
                    time.sleep(self.retry_backoff_s * attempt)
                    continue
                raise

        raise last_exc


def add_field_to_index(
    index_definition: JsonDict,
    field_name: str,
    field_type: str = "Edm.String",
    **field_properties
) -> bool:
    """
    Adds a field to the index definition
    
    Returns:
        True if field was added, False if already exists
    """
    fields = index_definition.get('fields', [])
    
    # Check if field already exists
    if any(field.get('name') == field_name for field in fields):
        return False
    
    # Default field structure
    new_field = {
        "name": field_name,
        "type": field_type,
        "searchable": False,
        "filterable": False,
        "retrievable": True,
        "stored": True,
        "sortable": False,
        "facetable": False,
        "key": False,
        "indexAnalyzer": None,
        "searchAnalyzer": None,
        "analyzer": None,
        "normalizer": None,
        "dimensions": None,
        "vectorSearchProfile": None,
        "vectorEncoding": None,
        "permissionFilter": None,
        "sensitivityLabel": None,
        "synonymMaps": []
    }
    
    # Append additional properties from parameters
    new_field.update(field_properties)
    
    # Add the field
    fields.append(new_field)
    index_definition['fields'] = fields
    
    return True

def add_field_mapping_to_indexer(
    indexer_definition: JsonDict,
    source_field: str,
    target_field: str,
    delimiter: str
) -> bool:
    """
    Adds a field mapping to the indexer definition with use of mappingFunction: extractTokenAtPosition
    for product_id extraction from file name

    Args:
        indexer_definition: The indexer JSON definition
        source_field: Source field name (e.g., "metadata_storage_name")
        target_field: Target field name (e.g., "product_id")
        delimiter: Delimiter for extractTokenAtPosition function (e.g., "__")

    Returns:
        True if field was added, False otherwise
    """
    # Get fieldMappings array from indexer definition
    field_mappings = indexer_definition.get("fieldMappings")
    if not isinstance(field_mappings, list):
        return False

    # Check if mapping already exists
    if any(m.get("targetFieldName") == target_field for m in field_mappings):
        return False

    # New mapping definition with extractTokenAtPosition function
    new_mapping = {
        "sourceFieldName": source_field,
        "targetFieldName": target_field,
        "mappingFunction": {
            "name": "extractTokenAtPosition",
            "parameters": {
                "delimiter": delimiter,
                "position@odata.type": "#Int64",
                "position": 0
            }
        }
    }

    # Add the mapping (this updates fieldMappings in-place)
    field_mappings.append(new_mapping)

    return True

def add_field_mapping_to_skillset(
    skillset_definition: JsonDict,
    field_name: str,
    field_source: str,
    **field_properties
) -> bool:
    """
    Adds a field mapping to the skillset definition

    Returns:
    True if field was added, False if already exists (or structure missing)
    """
    # Get mapping node (indexProjections -> selectors -> mappings)
    index_projections = skillset_definition.get("indexProjections")
    if not isinstance(index_projections, dict):
        return False

    selectors = index_projections.get("selectors")
    if not isinstance(selectors, list) or not selectors:
        return False

    first_selector = selectors[0]
    if not isinstance(first_selector, dict):
        return False

    mappings = first_selector.get("mappings")
    if not isinstance(mappings, list):
        return False

    # Check if mapping already exists
    if any(m.get("name") == field_name for m in mappings):
        return False

    # New mapping definition
    new_mapping = {
    "name": field_name,
    "source": field_source,
    "inputs": []
    }
    new_mapping.update(field_properties)

    # Add the mapping (this updates selectors[0]["mappings"] in-place)
    mappings.append(new_mapping)

    return True


def provision_data_plane():
    """
    Data plane provisioning
    Create and modyfy data plane via REST API:
    - Creteate Knowledge Source (datasource, index, skillset, indexer)
    - Get and modyfy index to add field product_id
    - Get and modyfy skillset to add field product_id
    """
    # Sleep time (seconds) to wait before next operation
    index_name = "knowledgesource-index"
    indexer_name = "knowledgesource-indexer"
    skillset_name = "knowledgesource-skillset"
    sleep_time=10
    
    # Load environment variables
    load_dotenv()

    base_url = os.getenv("SEARCH_SERVICE_ENDPOINT")
    ai_endpoint = os.getenv("AI_SERVICE_ENDPOINT")
    api_version = os.getenv("SEARCH_API_VERSION")
    ai_model_deployment = os.getenv("AI_MODEL_DEPLOYMENT")
    ai_model_name = os.getenv("AI_MODEL_NAME")
    search_knowledgesource_name = os.getenv("SEARCH_KNOWLEDGESOURCE_NAME")
    storage_connection_string = os.getenv("STORAGE_CONNECTION_STRING")
    storage_containter_name = os.getenv("STORAGE_CONTAINER_NAME")
    search_product_id_delimiter = os.getenv("SEARCH_PRODUCT_ID_DELIMITER", "__")

    if not base_url or not api_version:
        raise ValueError("Missing required environment variables: SEARCH_SERVICE_BASE_URL, SEARCH_API_VERSION")
 
    # api-key
    #auth = SearchAuth(api_key="PUT-YOUR-SEARCH-SERVICE-ADMIN-API-KEY-HERE")

    # AAD token (Managed Identity)
    auth = SearchAuth(use_aad=True)

    client = AzureSearchRestClient(base_url, api_version, auth)

    print("START DATA PLANE PROVISIONING")

    definition_file_path = Path(__file__).parent / "definitions" / "knowledgesource.json"
    print(f"Knowledge Source definition json file: {definition_file_path}")

    try:
        # Create Knowledge Source
        request_params = {
            "knowledgesourceName": search_knowledgesource_name,
            "storageConnectionString": storage_connection_string,
            "aiEndpoint": ai_endpoint,
            "aiModelDeployment": ai_model_deployment,
            "aiMOdelName": ai_model_name,
            "containerName": storage_containter_name
        }

        client.request(
            "PUT",
            "/knowledgesources/knowledgesource",
            json_template_path=definition_file_path,
            template_params=request_params
        )
        print(f"Knowledge Source created successfully")
        print(f"Sleeping for {sleep_time} seconds...")
        time.sleep(sleep_time)

        """
        INDEX UPDATE -------------------------------
        """

        # Get index definition
        rest_response = client.request(
            "GET",
            f"/indexes('{index_name}')"
        )
        
        if rest_response:
            print(f"Retrieved index: {rest_response.get('name')}")
            
            # Add field product_id if not exists
            was_added = add_field_to_index(
                rest_response,
                field_name="product_id",
                field_type="Edm.String",
                filterable=True,
                facetable=True
            )
            
            if was_added:
                print(f"Added 'product_id' field to index definition json")
                
                # Update index
                updated_response = client.request(
                    "PUT",
                    f"/indexes('{index_name}')",
                    json_body=rest_response
                )
                print(f"Index updated successfully")
            else:
                print(f"Field 'product_id' already exists in index")
        else:
            print(f"Warning: Empty response for GET index '{index_name}'")

        print(f"Sleeping for {sleep_time} seconds...")
        time.sleep(sleep_time)


        """
        INDEXER UPDATE -------------------------------
        """

        # Get indexer definition
        rest_response = client.request(
            "GET",
            f"/indexers('{indexer_name}')"
        )

        if rest_response:
            print(f"Retrieved indexer: {rest_response.get('name')}")
            
            # Add field mapping to indexer for product_id
            was_added = add_field_mapping_to_indexer(
                rest_response,
                source_field="metadata_storage_name",
                target_field="product_id",
                delimiter=search_product_id_delimiter
            )
            
            if was_added:
                print(f"Added 'product_id' mapping to the indexer definition json")
                
                # Update indexer
                updated_response = client.request(
                    "PUT",
                    f"/indexers('{indexer_name}')",
                    json_body=rest_response
                )
                print(f"Indexer updated successfully")
            else:
                print(f"Warning: Mapping to the indexer not added!")
        else:
            print(f"Warning: Empty response for GET indexer '{indexer_name}'")


        """
        SKILLSET UPDATE -------------------------------
        """

        # Get skillset definition
        rest_response = client.request(
            "GET",
            f"/skillsets('{skillset_name}')"
        )

        if rest_response:
            print(f"Retrieved skillset: {rest_response.get('name')}")
            
            # Add skillset projection mapping for product_id
            was_added = add_field_mapping_to_skillset(
                rest_response,
                field_name="product_id",
                field_source="/document/product_id"
            )
            
            if was_added:
                print(f"Added 'product_id' mapping to skillset definition json")
                
                # Update skillset
                updated_response = client.request(
                    "PUT",
                    f"/skillsets('{skillset_name}')",
                    json_body=rest_response
                )
                print(f"Skillset updated successfully")
            else:
                print(f"Field 'product_id' already exists in skillset mapping or not appropriate skillset structure")
        else:
            print(f"Warning: Empty response for GET skillset '{skillset_name}'")


        print("Provisioning completed successfully.")

    except RuntimeError as e:
        print(f"Error: {e}")
        raise
    except Exception as e:
        print(f"Unexpected error: {type(e).__name__}: {e}")
        raise


if __name__ == "__main__":
    provision_data_plane()
