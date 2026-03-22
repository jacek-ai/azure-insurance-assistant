"""Run Azure AI Foundry evaluations against a Foundry Agent.

This module implements a minimal wrapper around the Foundry evaluation API
(`client.evals.*`) described in Microsoft Learn:
https://learn.microsoft.com/azure/foundry/observability/how-to/evaluate-agent

The key goal is to keep the code CI-friendly:
- By default, no network calls happen during normal `pytest` runs.
- A separate pytest smoke test can run the evaluation only when the required
  environment variables are provided.

Environment variables (aligned with this repo's conventions):
- `AI_SERVICE_PROJECT_ENDPOINT` (required)
- `AI_AGENT_NAME` (required)
- `AI_AGENT_VERSION` (optional; omit to use latest)
- `AI_MODEL_DEPLOYMENT` (required for AI-judge evaluators)

Optional overrides:
- `FOUNDRY_EVAL_DATASET_NAME`
- `FOUNDRY_EVAL_DATASET_VERSION`
- `FOUNDRY_EVAL_NAME`
- `FOUNDRY_EVAL_RUN_NAME`
"""

from __future__ import annotations

import json
import os
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Mapping

from azure.identity import DefaultAzureCredential


@dataclass(frozen=True)
class FoundryAgentEvalSettings:
    """Settings required to run a Foundry agent evaluation."""

    project_endpoint: str
    agent_name: str
    agent_version: str | None
    judge_model_deployment: str

    dataset_path: Path
    dataset_name: str
    dataset_version: str

    evaluation_name: str
    run_name: str

    poll_interval_seconds: int = 5
    timeout_seconds: int = 15 * 60


def _require_env(name: str) -> str:
    value = (os.getenv(name) or "").strip()
    if not value:
        raise RuntimeError(f"Missing required environment variable: {name}")
    return value


def _env_optional(name: str) -> str | None:
    value = (os.getenv(name) or "").strip()
    return value or None


def load_settings(*, dataset_path: str | Path) -> FoundryAgentEvalSettings:
    """Build settings from environment variables."""

    dataset_path = Path(dataset_path)
    if not dataset_path.exists():
        raise FileNotFoundError(f"Dataset file not found: {dataset_path}")

    project_endpoint = _require_env("AI_SERVICE_PROJECT_ENDPOINT")
    agent_name = _require_env("AI_AGENT_NAME")
    agent_version = _env_optional("AI_AGENT_VERSION")
    judge_model_deployment = _require_env("AI_MODEL_DEPLOYMENT")

    dataset_name = os.getenv("FOUNDRY_EVAL_DATASET_NAME", "insurance-assistant-eval-queries").strip()
    dataset_version = os.getenv(
        "FOUNDRY_EVAL_DATASET_VERSION",
        time.strftime("%Y%m%d-%H%M%S"),
    ).strip()

    evaluation_name = os.getenv("FOUNDRY_EVAL_NAME", "Insurance Assistant - Basic Agent Eval").strip()
    run_name = os.getenv("FOUNDRY_EVAL_RUN_NAME", f"basic-eval-{dataset_version}").strip()

    return FoundryAgentEvalSettings(
        project_endpoint=project_endpoint,
        agent_name=agent_name,
        agent_version=agent_version,
        judge_model_deployment=judge_model_deployment,
        dataset_path=dataset_path,
        dataset_name=dataset_name,
        dataset_version=dataset_version,
        evaluation_name=evaluation_name,
        run_name=run_name,
    )


def build_testing_criteria(*, judge_model_deployment: str) -> list[dict[str, Any]]:
    """Return 2-3 basic built-in evaluators for agent evaluations."""

    # The evaluator names follow the Microsoft Learn article:
    # - builtin.task_adherence uses the full output items (incl. tool calls)
    # - builtin.coherence uses only the assistant message text
    # - builtin.violence is a safety evaluator (doesn't require a judge model)
    return [
        {
            "type": "azure_ai_evaluator",
            "name": "Task Adherence",
            "evaluator_name": "builtin.task_adherence",
            "data_mapping": {
                "query": "{{item.query}}",
                "response": "{{sample.output_items}}",
            },
            "initialization_parameters": {"deployment_name": judge_model_deployment},
        },
        {
            "type": "azure_ai_evaluator",
            "name": "Coherence",
            "evaluator_name": "builtin.coherence",
            "data_mapping": {
                "query": "{{item.query}}",
                "response": "{{sample.output_text}}",
            },
            "initialization_parameters": {"deployment_name": judge_model_deployment},
        },
        {
            "type": "azure_ai_evaluator",
            "name": "Violence",
            "evaluator_name": "builtin.violence",
            "data_mapping": {
                "query": "{{item.query}}",
                "response": "{{sample.output_text}}",
            },
        },
    ]


def build_data_source_config() -> dict[str, Any]:
    """Return a minimal datasource schema for the JSONL dataset."""

    return {
        "type": "custom",
        "item_schema": {
            "type": "object",
            "properties": {
                "query": {"type": "string"},
            },
            "required": ["query"],
        },
        "include_sample_schema": True,
    }


def validate_jsonl_dataset(path: str | Path) -> list[Mapping[str, Any]]:
    """Validate and return items from a JSONL dataset.

    Each row must be a JSON object with a non-empty `query` string.
    """

    items: list[Mapping[str, Any]] = []
    path = Path(path)

    with path.open("r", encoding="utf-8") as file_handle:
        for line_no, raw_line in enumerate(file_handle, start=1):
            line = raw_line.strip()
            if not line:
                continue

            try:
                obj = json.loads(line)
            except json.JSONDecodeError as exc:
                raise ValueError(f"Invalid JSON at {path}:{line_no}: {exc}") from exc

            if not isinstance(obj, dict):
                raise ValueError(f"Expected JSON object at {path}:{line_no}")

            query = obj.get("query")
            if not isinstance(query, str) or not query.strip():
                raise ValueError(f"Missing/invalid 'query' at {path}:{line_no}")

            items.append(obj)

    if not items:
        raise ValueError(f"Dataset is empty: {path}")

    return items


def run_agent_evaluation(settings: FoundryAgentEvalSettings) -> dict[str, Any]:
    """Create and run a Foundry evaluation, then wait for completion.

    Returns a dict with:
    - evaluation_id
    - run_id
    - status
    - report_url
    - aggregated_results (best-effort; may be empty if API shape changes)
    """

    # Pre-validate dataset locally to fail fast.
    validate_jsonl_dataset(settings.dataset_path)

    try:
        from azure.ai.projects import AIProjectClient
    except ImportError as exc:  # pragma: no cover
        raise RuntimeError(
            "Missing dependency: azure-ai-projects. Install it (e.g. pip install azure-ai-projects) "
            "or install from src/requirements.txt"
        ) from exc

    credential = DefaultAzureCredential()
    project_client = AIProjectClient(endpoint=settings.project_endpoint, credential=credential)

    # The OpenAI-compatible client contains `evals` in the Foundry SDK.
    client = project_client.get_openai_client()

    dataset = project_client.datasets.upload_file(
        name=settings.dataset_name,
        version=settings.dataset_version,
        file_path=str(settings.dataset_path),
    )

    evaluation = client.evals.create(
        name=settings.evaluation_name,
        data_source_config=build_data_source_config(),
        testing_criteria=build_testing_criteria(
            judge_model_deployment=settings.judge_model_deployment
        ),
    )

    target: dict[str, Any] = {"type": "azure_ai_agent", "name": settings.agent_name}
    if settings.agent_version:
        target["version"] = settings.agent_version

    eval_run = client.evals.runs.create(
        eval_id=evaluation.id,
        name=settings.run_name,
        data_source={
            "type": "azure_ai_target_completions",
            "source": {
                "type": "file_id",
                "id": dataset.id,
            },
            "input_messages": {
                "type": "template",
                "template": [
                    {
                        "type": "message",
                        "role": "user",
                        "content": {
                            "type": "input_text",
                            "text": "{{item.query}}",
                        },
                    }
                ],
            },
            "target": target,
        },
    )

    deadline = time.time() + settings.timeout_seconds
    last_run: Any | None = None
    while time.time() < deadline:
        last_run = client.evals.runs.retrieve(run_id=eval_run.id, eval_id=evaluation.id)
        if getattr(last_run, "status", None) in {"completed", "failed"}:
            break
        time.sleep(settings.poll_interval_seconds)

    if last_run is None:
        raise RuntimeError("Failed to retrieve evaluation run status")

    status = getattr(last_run, "status", "unknown")
    report_url = getattr(last_run, "report_url", None)

    # Best-effort aggregated results (SDK surface may evolve).
    aggregated_results: dict[str, Any] = {}
    try:
        aggregated_results = client.evals.runs.results.retrieve(
            run_id=eval_run.id, eval_id=evaluation.id
        )
    except Exception:
        aggregated_results = {}

    return {
        "evaluation_id": evaluation.id,
        "run_id": eval_run.id,
        "status": status,
        "report_url": report_url,
        "aggregated_results": aggregated_results,
    }
