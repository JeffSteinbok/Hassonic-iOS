#!/usr/bin/env python3
"""Export a sanitized inventory of your Home Assistant's entities.

Writes docs/home-assistant-entities.json (gitignored): every entity's ID,
name and state, with private domains and attributes left out. Handy when
writing a config, or as context for a coding assistant.

  scripts/export_ha_entities.py                    # HA_URL/HA_TOKEN from .ha.env
  scripts/export_ha_entities.py --input states.json
"""

import argparse
import json
import re
import urllib.request
from collections import Counter
from datetime import datetime, timezone
from pathlib import Path

from ha_env import load_env, require


PRIVATE_DOMAINS = {
    "alarm_control_panel",
    "calendar",
    "camera",
    "device_tracker",
    "image",
    "lock",
    "notify",
    "person",
    "todo",
    "zone",
}

PRIVATE_NAME = re.compile(
    r"(^|_)(access_token|address|api_key|bssid|email|gps|host|ip|ipv4|ipv6|"
    r"entity_picture|image_url|latitude|location|longitude|mac|password|phone|"
    r"remote_address|serial|ssid|thumbnail|token|user_id|webhook|wifi_mac|"
    r"zip_code)($|_)",
    re.IGNORECASE,
)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Export a sanitized Home Assistant entity inventory."
    )
    parser.add_argument(
        "--input", type=Path,
        help="An HA states JSON file, instead of asking Home Assistant (HA_URL and HA_TOKEN in .ha.env).",
    )
    parser.add_argument(
        "--output",
        type=Path,
        default=Path("docs/home-assistant-entities.json"),
    )
    return parser.parse_args()


def load_states(args: argparse.Namespace) -> list[dict]:
    if args.input:
        with args.input.open(encoding="utf-8") as handle:
            return json.load(handle)

    env = load_env()
    token = require(env, "HA_TOKEN")
    request = urllib.request.Request(
        f"{require(env, 'HA_URL').rstrip('/')}/api/states",
        headers={"Authorization": f"Bearer {token}", "Content-Type": "application/json"},
    )
    with urllib.request.urlopen(request, timeout=30) as response:
        return json.load(response)


def is_private_name(name: str) -> bool:
    return PRIVATE_NAME.search(name.replace("-", "_")) is not None


def sanitize_value(value):
    if isinstance(value, dict):
        return {
            key: sanitize_value(item)
            for key, item in value.items()
            if not is_private_name(key)
        }
    if isinstance(value, list):
        return [sanitize_value(item) for item in value]
    return value


def sanitize(states: list[dict]) -> tuple[list[dict], Counter]:
    entities = []
    redactions = Counter()

    for state in states:
        entity_id = state.get("entity_id") or state.get("entityId")
        if not entity_id or "." not in entity_id:
            redactions["invalid_entity"] += 1
            continue

        domain = entity_id.split(".", 1)[0]
        if domain in PRIVATE_DOMAINS:
            redactions[f"private_domain:{domain}"] += 1
            continue
        if is_private_name(entity_id):
            redactions["private_entity_id"] += 1
            continue

        attributes = sanitize_value(state.get("attributes", {}))
        entities.append(
            {
                "entity_id": entity_id,
                "domain": domain,
                "friendly_name": attributes.get("friendly_name", entity_id),
                "state": state.get("state"),
                "attributes": attributes,
            }
        )

    entities.sort(key=lambda entity: entity["entity_id"])
    return entities, redactions


def main() -> None:
    args = parse_args()
    states = load_states(args)
    entities, redactions = sanitize(states)
    payload = {
        "schema_version": 1,
        "generated_at": datetime.now(timezone.utc).isoformat(),
        "source_entity_count": len(states),
        "exported_entity_count": len(entities),
        "redactions": dict(sorted(redactions.items())),
        "entities": entities,
    }

    args.output.parent.mkdir(parents=True, exist_ok=True)
    with args.output.open("w", encoding="utf-8") as handle:
        json.dump(payload, handle, indent=2, sort_keys=True)
        handle.write("\n")

    print(f"Wrote {len(entities)} sanitized entities to {args.output}")


if __name__ == "__main__":
    main()
