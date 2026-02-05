"""Create an Insurance Assistant agent in an Azure AI Project.

This script reads configuration from environment variables and creates a new
agent version that can call the deployed Functions API as agent's tools.
"""

import os
import sys

from dotenv import load_dotenv

from azure.ai.projects import AIProjectClient
from azure.ai.projects.models import PromptAgentDefinition

from tools.function_openapi_tool import build_insurance_functions_tool

try:
    from azure.identity import DefaultAzureCredential
except ImportError:
    DefaultAzureCredential = None

DEFAULT_FUNCTION_PROJECT_CONNECTION_NAME = "con-function-insurance-assistance"


def _require_env(name: str, hint: str) -> str:
    """Read a required environment variable."""

    value = os.getenv(name)
    if value:
        return value

    print(hint)
    sys.exit(1)


# Agent instructions with product filtering guidance
AGENT_INSTRUCTIONS = """
Jesteś asystentem dla agenta ubezpieczeniowego. Masz dostęp do informacji o różnych produktach ubezpieczeniowych poprzez dwa narzędzia.

Zanim odpowiesz merytorycznie na pytanie, MUSISZ najpierw jednoznacznie ustalić, którego produktu dotyczy pytanie.
Jeśli produkt nie jest jednoznaczny, najpierw doprecyzuj produkt (zanim przejdziesz do wyszukiwania chunków).

Masz DWA narzędzia:
1) insurance_functions.list_products – pobiera listę produktów (z opcjonalnymi filtrami).
    - Parametry wejściowe: product_type (opcjonalnie), date (opcjonalnie, format YYYY-MM-DD; zwraca produkty ważne w tej dacie).
    - Zwraca: products[] oraz ewentualnie error.
2) insurance_functions.search_chunks – wyszukuje chunki w Azure AI Search.
    - Parametry wejściowe: query (pytanie użytkownika), product_id (MUSI być jednoznaczny), top (opcjonalnie).
    - Zwraca: chunks[] oraz ewentualnie error.

Kluczowa zasada bezpieczeństwa i jakości:
- NIE WOLNO wywoływać insurance_functions.search_chunks, jeśli nie udało się ustalić jednoznacznie product_id.

Jak pracujesz (flow):
1) Najpierw ustal kontekst produktu.
    - Jeśli użytkownik podał product_id wprost, użyj go.
    - Jeśli nie podał product_id albo jest niejednoznaczny, użyj insurance_functions.list_products, aby zawęzić wybór.
    Możesz (i powinieneś) dopytywać o: rodzaj produktu (product_type), datę (YYYY-MM-DD), nazwę/wersję.
    Możesz też zaproponować użytkownikowi wyświetlenie listy produktów, o których posiadasz informacje.

2) Interpretacja wyniku list_products:
    - Dokładnie 1 produkt: zapamiętaj jego product_id i posługuj się nim w kolejnych krokach.
     - >1 produktu: pokaż krótką, czytelną listę opcji w formie numerowanej (1, 2, 3, ...).
         Przy każdej pozycji pokaż minimum: product_name, product_version_no, product_type, date_from–date_to oraz product_id.
         Następnie poproś użytkownika o wybór poprzez wpisanie samego numeru (np. "1" albo "2").
         Jeśli użytkownik odpowie numerem, wybierz odpowiadającą pozycję z ostatnio pokazanej listy i użyj jej product_id.
         W tym stanie (dopóki nie ma jednoznacznego wyboru) NIE WOLNO wyszukiwać chunków.
    - 0 produktów: pobierz ponownie listę produktów z żadnymi filtrami i spróbuj zidentyfikować produkt na podstawie nazwy/wersji.
            Jeśli nadal 0 produktów, poinformuj, że nie znaleziono pasujących produktów i poproś o doprecyzowanie (typ, data, nazwa). 
            Wyraźnie poinformuj, że możesz wyświetlić listę dostępnych produktów.


3) Dopiero gdy product_id jest jednoznaczny i użytkownik zadaje pytanie merytoryczne (warunki, zakres, wyłączenia, definicje, procedury),
    wywołaj insurance_functions.search_chunks.

Zasady odpowiedzi:
- Odpowiadaj po polsku, krótko i precyzyjnie, opierając się na zwróconych chunkach.
- Jeśli w chunkach nie ma odpowiedzi, powiedz wprost, czego brakuje i poproś o doprecyzowanie.
- Dodawaj cytowania jako wskazanie źródła (np. metadata_storage_name / metadata_storage_path), jeśli są dostępne.
"""


def main() -> None:
    """Create a new agent version in the configured AI Project."""

    load_dotenv()

    function_base_url = _require_env(
        "FUNCTION_BASE_URL",
        "Please set FUNCTION_BASE_URL (e.g. https://<your-functionapp>.azurewebsites.net).",
    )
    project_endpoint = _require_env(
        "AI_SERVICE_PROJECT_ENDPOINT",
        "Please set the AI_SERVICE_PROJECT_ENDPOINT environment variable.",
    )

    function_connection_name = (
        os.getenv("FUNCTION_PROJECT_CONNECTION_NAME")
        or DEFAULT_FUNCTION_PROJECT_CONNECTION_NAME
    )
    agent_name = os.getenv("AI_AGENT_NAME")

    print(f"Project Endpoint: {project_endpoint}")
    if not os.getenv("FUNCTION_PROJECT_CONNECTION_NAME"):
        print(
            "FUNCTION_PROJECT_CONNECTION_NAME not set; using default: "
            f"{DEFAULT_FUNCTION_PROJECT_CONNECTION_NAME}"
        )

    credential = DefaultAzureCredential(
        exclude_environment_credential=True,
        exclude_managed_identity_credential=True,
    )
    project_client = AIProjectClient(endpoint=project_endpoint, credential=credential)
    if project_client:
        print(f"PROJECT: {project_client}")
    else:
        print("Failed to create project client.")
        sys.exit(1)

    try:
        function_connection = project_client.connections.get(function_connection_name)
    except Exception as e:
        print(
            f"Error: failed to get Function connection '{function_connection_name}': {e}"
        )
        sys.exit(1)

    print(
        f"Using Function connection: {function_connection.name} (ID: {function_connection.id})"
    )

    openapi_spec_path = os.path.join(
        os.path.dirname(__file__), "assets", "function_openapi.json"
    )
    function_tool = build_insurance_functions_tool(
        function_base_url=function_base_url,
        function_connection_id=function_connection.id,
        openapi_spec_path=openapi_spec_path,
    )

    agent = project_client.agents.create_version(
        agent_name=agent_name,
        definition=PromptAgentDefinition(
            model="gpt-4o",
            instructions=AGENT_INSTRUCTIONS,
            tools=[function_tool],
        ),
    )
    print(f"Created agent: {agent.name} (version: {agent.version})")


if __name__ == "__main__":
    main()
