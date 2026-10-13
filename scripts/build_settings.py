#!/usr/bin/env python3

"""Reads values from Config/Base.xcconfig and the gitignored Local.xcconfig.

Scripts that need the app's bundle ID or team ask here instead of hard-coding
them, so a fork only sets them once, in Local.xcconfig.

    scripts/build_settings.py DEVELOPMENT_TEAM
"""

import re
import sys
from pathlib import Path


CONFIG_DIR = Path(__file__).resolve().parent.parent / "Config"


def _read(path: Path, values: dict[str, str]) -> None:
    if not path.exists():
        return
    for line in path.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if line.startswith("#include"):
            _read(path.parent / line.split('"')[1], values)
            continue
        if not line or line.startswith("//") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        values[key.strip()] = value.split("//", 1)[0].strip().replace("$()", "")


def xcconfig_value(name: str) -> str:
    values: dict[str, str] = {}
    _read(CONFIG_DIR / "Base.xcconfig", values)
    value = values.get(name, "")
    # Expand $(OTHER) references, as Xcode does.
    while (match := re.search(r"\$\((\w+)\)", value)):
        value = value.replace(match.group(0), values.get(match.group(1), ""))
    return value


def app_bundle_id(configuration: str = "Debug") -> str:
    """The app's bundle ID as project.yml builds it for `configuration`."""
    bundle_id = xcconfig_value("APP_BUNDLE_ID")
    return f"{bundle_id}.dev" if configuration == "Debug" else bundle_id


if __name__ == "__main__":
    print(xcconfig_value(sys.argv[1]))
