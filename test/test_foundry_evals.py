"""Optional Foundry evaluation tests.

These tests are meant to be run manually (or in a dedicated pipeline) because they
require Azure credentials and a deployed Foundry project/agent.

To run locally:
- Set env vars: `AI_SERVICE_PROJECT_ENDPOINT`, `AI_AGENT_NAME`, `AI_MODEL_DEPLOYMENT`
- Authenticate (e.g., `az login`) so `DefaultAzureCredential` works
- Run: `RUN_FOUNDRY_EVALS=1 python -m pytest -k foundry_evals`
"""

from __future__ import annotations

import os
from pathlib import Path

import pytest

from evals.foundry_agent_eval import (
    load_settings,
    run_agent_evaluation,
    validate_jsonl_dataset,
)


DATASET_PATH = Path(__file__).parent / "test-data" / "agent-eval-queries.jsonl"


def test_eval_dataset_is_valid_jsonl() -> None:
    items = validate_jsonl_dataset(DATASET_PATH)
    assert len(items) >= 2


@pytest.mark.foundry_eval
@pytest.mark.skipif(
    os.getenv("RUN_FOUNDRY_EVALS") != "1",
    reason="Set RUN_FOUNDRY_EVALS=1 and provide Azure Foundry env vars to run",
)
def test_foundry_agent_eval_smoke() -> None:
    settings = load_settings(dataset_path=DATASET_PATH)
    result = run_agent_evaluation(settings)

    assert result["status"] in {"completed", "failed"}
    assert result["evaluation_id"]
    assert result["run_id"]

    # If completed, we expect to get a portal report URL.
    if result["status"] == "completed":
        assert result["report_url"], "Expected report_url for a completed run"
