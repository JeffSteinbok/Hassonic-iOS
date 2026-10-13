"""Shared loader for the gitignored .ha.env file at the repository root.

Keeps Home Assistant credentials out of shell history and out of script
arguments — nothing here ever prints a value.
"""

import os
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parent.parent
ENV_FILE = REPO_ROOT / ".ha.env"


def load_env() -> dict[str, str]:
    values = {}

    if ENV_FILE.exists():
        for line in ENV_FILE.read_text(encoding="utf-8").splitlines():
            line = line.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            key, value = line.split("=", 1)
            values[key.strip()] = value.strip().strip("\"'")

    # A real environment variable wins, so a one-off override needs no edit.
    values.update({key: value for key, value in os.environ.items() if key.startswith("HA_")})
    return values


def require(values: dict[str, str], key: str) -> str:
    value = values.get(key)
    if not value:
        raise SystemExit(f"{key} is not set (add it to {ENV_FILE.name} or export it)")
    return value
