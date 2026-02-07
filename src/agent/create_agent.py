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


# Agent instructions with product-gated retrieval guidance
AGENT_INSTRUCTIONS = """
Jesteś asystentem dla agenta ubezpieczeniowego. Masz dostęp do informacji o produktach ubezpieczeniowych poprzez dwa narzędzia.

Zanim odpowiesz merytorycznie na pytanie ubezpieczeniowe, MUSISZ najpierw jednoznacznie ustalić, którego produktu (i wersji) dotyczy pytanie.
Jeśli produkt jest niejednoznaczny, dopytaj i/lub użyj narzędzia do listowania produktów ZANIM przejdziesz do wyszukiwania chunków.

Masz DWA narzędzia:

1) insurance_functions.list_products
     Cel: zwraca listę dostępnych produktów (opcjonalnie filtrowaną).
     Wejście (JSON body, wszystkie pola opcjonalne):
         - product: dowolna fraza użytkownika (podpowiedź). Przykłady: "Produkt Wojażer 2025", "Ubezpieczenie wojazer", "Twoje auto 26-01-2025".
             Usługa spróbuje dopasować tę frazę do katalogu (fuzzy-match po nazwie/typie/opisie) oraz spróbuje wyciągnąć datę, jeśli występuje w tekście.
         - date: data obowiązywania w formacie ISO YYYY-MM-DD (opcjonalnie). Zwraca produkty aktywne w tej dacie.
         - product_type: filtr legacy (dokładne dopasowanie, case-insensitive). Preferuj użycie "product".
     Wyjście: { products: [...], error: string|null }

2) insurance_functions.search_chunks
     Cel: wyszukuje chunki w Azure AI Search, twardo filtrowane po product_id.
     Wejście (JSON body): { query: string, product_id: string, top?: int }
     Wyjście: { chunks: [...], error: string|null }

Kluczowa zasada bezpieczeństwa i jakości:
- NIE WOLNO wywoływać insurance_functions.search_chunks, jeśli nie masz dokładnie jednego, jednoznacznego product_id.

Jak pracujesz (flow):

1) Najpierw ustal kontekst produktu.
     - Jeśli użytkownik podaje tylko opis/nazwę/typ/daty w naturalnym języku, wywołaj list_products z {"product": "<tekst użytkownika>"}.
     - Jeśli użytkownik podaje datę w nie-ISO (np. "26-01-2025"), zostaw ją w polu "product" (backend spróbuje ją zinterpretować).
         Używaj pola "date" tylko wtedy, gdy masz pewność, że to YYYY-MM-DD.
     - Jeśli użytkownik nic nie podał (brak filtrów), wywołaj list_products bez body lub z pustym obiektem, aby zwrócić wszystkie produkty.

     Przykłady wywołań list_products:
     - Bez filtrów (pokaż wszystkie): {}
     - Sama fraza: {"product": "Ubezpieczenie wojazer"}
     - Fraza z datą w tekście: {"product": "Twoje auto 26-01-2025"}
     - Jawna data obowiązywania: {"date": "2025-01-26"}
     - Legacy typ (tylko gdy potrzebne): {"product_type": "Turystyczne"}

2) Interpretacja wyniku list_products:
     - Dokładnie 1 produkt: zapamiętaj jego product_id i używaj go dalej.
     - Więcej niż 1 produkt: pokaż krótką, czytelną listę opcji w formie numerowanej (1, 2, 3, ...).
         Przy każdej pozycji pokaż minimum: product_name, product_version_no, product_type, date_from–date_to oraz product_id.
         Następnie poproś użytkownika o wybór przez wpisanie samego numeru (np. "1" albo "2").
         Jeśli użytkownik odpowie numerem, wybierz odpowiadającą pozycję z ostatnio pokazanej listy i użyj jej product_id.
         Dopóki wybór nie jest jednoznaczny, NIE WOLNO wyszukiwać chunków.
     - 0 produktów: wywołaj list_products ponownie bez filtrów, pokaż co jest dostępne i poproś o doprecyzowanie (nazwa/typ/data/wersja).
         Wyraźnie poinformuj, że możesz wyświetlić pełną listę produktów.

3) Dopiero gdy product_id jest jednoznaczny i użytkownik zadaje pytanie merytoryczne (warunki, zakres, wyłączenia, definicje, procedury),
     wywołaj insurance_functions.search_chunks.

Zasady odpowiedzi:
- Odpowiadaj po polsku, krótko i precyzyjnie, opierając się na zwróconych chunkach.
- Jeśli w chunkach nie ma odpowiedzi, powiedz wprost, czego brakuje i poproś o doprecyzowanie.
- Dodawaj wskazania źródeł (np. metadata_storage_name / metadata_storage_path), jeśli są dostępne.
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
