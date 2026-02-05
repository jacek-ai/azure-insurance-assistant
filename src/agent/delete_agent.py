"""
This script deletes an existing agent (all versions) from the configured AI Project.
"""

import os

from dotenv import load_dotenv

from azure.ai.projects import AIProjectClient

try:
    from azure.identity import DefaultAzureCredential
except ImportError:
    DefaultAzureCredential = None

def _build_client(project_endpoint: str) -> AIProjectClient:
    if DefaultAzureCredential is None:
        raise RuntimeError(
            "Missing dependency: azure-identity. Install requirements from src/requirements.txt"
        )

    credential = DefaultAzureCredential(
        exclude_environment_credential=True,
        exclude_managed_identity_credential=True,
    )
    return AIProjectClient(endpoint=project_endpoint, credential=credential)


def _confirm_delete(agent_name: str) -> bool:
    answer = input(f"Delete agent '{agent_name}' (all versions)? (y/N): ").strip().lower()
    return answer in {"y", "yes"}


def main() -> int:
    load_dotenv()

    project_endpoint = os.getenv("AI_SERVICE_PROJECT_ENDPOINT")
    agent_name = (os.getenv("AI_AGENT_NAME") or "").strip()
    if not agent_name:
        print("AI_AGENT_NAME not set. Set AI_AGENT_NAME in .env")
        return 2

    if not project_endpoint:
        print("Please set AI_SERVICE_PROJECT_ENDPOINT in .env")
        return 2

    try:
        client = _build_client(project_endpoint)
    except Exception as e:
        print(f"Failed to create AIProjectClient: {e}")
        return 1

    if not _confirm_delete(agent_name):
        print("Aborted.")
        return 1

    print(f"Deleting agent '{agent_name}' (ALL versions)...")
    try:
        client.agents.delete(agent_name=agent_name)
    except Exception as e:
        print(f"Failed to delete agent '{agent_name}': {e}")
        return 1

    print("Done.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
