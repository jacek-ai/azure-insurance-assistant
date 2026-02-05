"""Pytest configuration.

This test suite imports code from folders that are not installed as packages in the active
environment (e.g., Azure Functions entrypoints and agent scripts). To keep local and CI
test runs simple, we add those source roots to ``sys.path`` at collection time.
"""

from __future__ import annotations

import sys
from pathlib import Path


def _add_to_syspath(path: Path) -> None:
    """Prepend *path* to ``sys.path`` if not already present.

    We insert at position 0 to ensure local sources take precedence over any globally
    installed packages with the same module name.
    """
    resolved = str(path.resolve())
    if resolved not in sys.path:
        sys.path.insert(0, resolved)


# Allow importing modules that live outside a Python package.
REPO_ROOT = Path(__file__).resolve().parents[1]
_add_to_syspath(REPO_ROOT / "src" / "functions" / "insurance-assistant-functions")
_add_to_syspath(REPO_ROOT / "src" / "agent")
