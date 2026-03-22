"""CLI entrypoint for running Foundry agent evaluations.

Usage (PowerShell):

    python ./src/evals/run_foundry_agent_eval.py --dataset ./test/test-data/agent-eval-queries.jsonl

Required environment variables:
- `AI_SERVICE_PROJECT_ENDPOINT`
- `AI_AGENT_NAME`
- `AI_MODEL_DEPLOYMENT`

Optional:
- `AI_AGENT_VERSION`
"""

from __future__ import annotations

import argparse
import json

from foundry_agent_eval import load_settings, run_agent_evaluation


def main() -> int:
    parser = argparse.ArgumentParser(description="Run Azure AI Foundry evals for the insurance agent")
    parser.add_argument(
        "--dataset",
        required=True,
        help="Path to a JSONL file with {\"query\": \"...\"} rows",
    )

    args = parser.parse_args()
    settings = load_settings(dataset_path=args.dataset)
    result = run_agent_evaluation(settings)

    print(json.dumps(result, indent=2, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
