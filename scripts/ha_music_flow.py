#!/usr/bin/env python3
"""
Exercises the same account-switching flow the app's PlayOnSheet uses, directly
against a live Home Assistant instance, so it can be iterated on without going
through the simulator or a physical device.

Mirrors PlayOnSheet.performSwitch / HAWebSocketClient.switchSpeakerToAccount:
1. Try select_source directly.
2. If it doesn't confirm within a few seconds, that's the signal the zone
   isn't on this account (select_source "succeeds" with no error even when
   it's a no-op, so a timeout is the only way to detect that).
3. Send the Alexa voice commands directly (account switch, then a real
   "play" command to force the Connect handoff) — polling last_called_response
   for the switch to confirm before sending the play command.
4. Try select_source again.

Reads accounts and zones from the app's config, hassonic.yaml (its
`media` and `speakerClaim` sections), so it never drifts from what the app
uses. Pass --config for another copy.

Credentials: HA_URL and HA_TOKEN from .ha.env (gitignored) at the repo
root, or the environment.

Usage:
  scripts/ha_music_flow.py status
  scripts/ha_music_flow.py status --account Morgan
  scripts/ha_music_flow.py play-on Morgan Kitchen
"""

import argparse
import json
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path

from build_settings import xcconfig_value
from ha_env import load_env, require

REPO_ROOT = Path(__file__).resolve().parent.parent
CONFIG_PATH = REPO_ROOT / f"{xcconfig_value('CONFIG_NAME')}.yaml"


def load_music_config(path: Path = CONFIG_PATH) -> dict:
    """The accounts and claim devices from the app config, in the shape the
    commands below use."""
    import yaml  # PyYAML; only this script needs it.

    with path.open(encoding="utf-8") as handle:
        config = yaml.safe_load(handle)
    accounts = []
    for account in config.get("media", {}).get("accounts", []):
        account = dict(account)
        account.setdefault("speakers", [])
        account.setdefault("groups", [])
        for zone in account["speakers"] + account["groups"]:
            zone.setdefault("spotifySourceName", zone.get("sourceName"))
        accounts.append(account)
    claim = config.get("speakerClaim") or {}
    return {"spotifyAccounts": accounts, "alexaSwitchingDeviceIds": claim.get("deviceEntityIds", [])}


def find_account(config: dict, display_name: str) -> dict:
    for account in config["spotifyAccounts"]:
        if account["displayName"].lower() == display_name.lower():
            return account
    available = ", ".join(a["displayName"] for a in config["spotifyAccounts"])
    raise SystemExit(f"Unknown account '{display_name}'. Available: {available}")


def find_zone(account: dict, display_name: str) -> dict:
    for zone in account["speakers"] + account["groups"]:
        if zone["displayName"].lower() == display_name.lower():
            return zone
    available = ", ".join(z["displayName"] for z in account["speakers"] + account["groups"])
    raise SystemExit(f"Unknown zone '{display_name}' for this account. Available: {available}")


class HAClient:
    def __init__(self, base_url: str, token: str):
        self.base_url = base_url.rstrip("/")
        self.token = token

    def _request(self, method: str, path: str, body: dict | None = None):
        data = json.dumps(body).encode("utf-8") if body is not None else None
        request = urllib.request.Request(
            f"{self.base_url}{path}",
            data=data,
            method=method,
            headers={
                "Authorization": f"Bearer {self.token}",
                "Content-Type": "application/json",
            },
        )
        try:
            with urllib.request.urlopen(request, timeout=30) as response:
                raw = response.read()
                return json.loads(raw) if raw else None
        except urllib.error.HTTPError as error:
            detail = error.read().decode("utf-8", errors="replace")
            raise SystemExit(f"HA request failed: {method} {path} -> {error.code} {detail}")

    def get_state(self, entity_id: str) -> dict:
        return self._request("GET", f"/api/states/{entity_id}")

    def call_service(self, domain: str, service: str, data: dict) -> object:
        return self._request("POST", f"/api/services/{domain}/{service}", data)

    def send_alexa_custom_command(self, alexa_entity_id: str, phrase: str) -> None:
        self.call_service("media_player", "play_media", {
            "entity_id": alexa_entity_id,
            "media": {"media_content_id": phrase, "media_content_type": "custom", "metadata": {}},
        })


def normalize(value: str) -> str:
    return " ".join(value.strip().lower().split())


def wait_for_source_confirmed(client: HAClient, spotify_entity_id: str, source_name: str,
                               timeout_seconds: float = 5) -> bool:
    started = time.monotonic()
    target = normalize(source_name)
    while time.monotonic() - started < timeout_seconds:
        state = client.get_state(spotify_entity_id)
        current = state.get("attributes", {}).get("source")
        if current and normalize(current) == target:
            print(f"  select_source confirmed in {time.monotonic() - started:.1f}s")
            return True
        time.sleep(0.5)
    print(f"  select_source not confirmed after {timeout_seconds}s")
    return False


def response_since(client: HAClient, alexa_entity_id: str, sent_at: float) -> str | None:
    """`sent_at` is a time.time()-based (epoch) timestamp of when we sent the
    command. Only returns a response if it's genuinely newer than that — not
    just "recent" relative to now — otherwise a stale response from an
    unrelated earlier command can look valid and get misread as the answer
    to this one (e.g. reporting the wrong account entirely). Small tolerance
    for clock skew between this machine and Home Assistant's server."""
    state = client.get_state(alexa_entity_id)
    attrs = state.get("attributes", {})
    ts_ms = attrs.get("last_called_timestamp")
    if ts_ms is None:
        return None
    called_at = ts_ms / 1000
    if called_at <= sent_at - 2:
        return None
    return attrs.get("last_called_response")


def attempt_account_switch(client: HAClient, alexa_entity_id: str, account: str) -> str:
    """One switch attempt + poll, no retry. Returns "confirmed", "no_response",
    or the actual wrong response string."""
    switch_phrase = f"Switch to {account}'s account"
    print(f"  [alexa] -> {alexa_entity_id}: \"{switch_phrase}\"")
    sent_at = time.time()
    client.send_alexa_custom_command(alexa_entity_id, switch_phrase)

    # Measured live: a genuine round trip can take over 8s (one clean sample
    # took 11.2s) — a shorter window made attempt 1 time out and fire a
    # needless, audible second "Switch to..." command before the first
    # one's real answer had even arrived.
    started = time.monotonic()
    while time.monotonic() - started < 16:
        time.sleep(0.5)
        response = response_since(client, alexa_entity_id, sent_at)
        if response is None:
            continue
        elapsed = time.monotonic() - started
        if f"in {account}'s account".lower() in response.lower():
            print(f"  [alexa] {alexa_entity_id} confirmed in {elapsed:.1f}s")
            return "confirmed"
        print(f"  [alexa] {alexa_entity_id} said \"{response}\" after {elapsed:.1f}s")
        return response
    print(f"  [alexa] {alexa_entity_id} gave no response after 16s")
    return "no_response"


def switch_speaker_to_account(client: HAClient, alexa_entity_ids: list[str], account: str, speaker: str) -> str:
    """Mirrors HAWebSocketClient.switchSpeakerToAccount: tries each device in
    order, one retry on the same device for ANY failure (wrong account or no
    response), then falls back to the next device. Returns "confirmed" or a
    failure summary."""
    for i, alexa_entity_id in enumerate(alexa_entity_ids):
        print(f"  [alexa] trying device: {alexa_entity_id}")
        confirmed = False
        for attempt in (1, 2):
            outcome = attempt_account_switch(client, alexa_entity_id, account)
            if outcome == "confirmed":
                confirmed = True
                break
            description = "didn't respond" if outcome == "no_response" else f"said \"{outcome}\""
            if attempt == 1:
                print(f"  [alexa] {description}, retrying same device")
            else:
                print(f"  [alexa] still {description} after retry")
        if confirmed:
            time.sleep(1.5)  # cooldown before the second command to the same device
            play_phrase = f"Play U2 on Spotify on {speaker}"
            print(f"  [alexa] -> {alexa_entity_id}: \"{play_phrase}\"")
            client.send_alexa_custom_command(alexa_entity_id, play_phrase)
            time.sleep(3)
            return "confirmed"
        if i < len(alexa_entity_ids) - 1:
            print(f"  [alexa] falling back to {alexa_entity_ids[i + 1]}")
    return f"failed: none of {alexa_entity_ids} could switch to {account}'s account"


def cmd_status(client: HAClient, config: dict, only_account: str | None) -> None:
    accounts = config["spotifyAccounts"]
    if only_account:
        accounts = [find_account(config, only_account)]

    for account in accounts:
        state = client.get_state(account["entityId"])
        attrs = state.get("attributes", {})
        print(f"== {account['displayName']} ({account['entityId']}) ==")
        print(f"  state:       {state.get('state')}")
        print(f"  source:      {attrs.get('source')}")
        print(f"  source_list: {attrs.get('source_list')}")
        zone_names = [z["displayName"] for z in account["speakers"] + account["groups"] if z.get("isEnabled", True)]
        print(f"  zones known to app: {zone_names}")
        print()


def cmd_play_on(client: HAClient, config: dict, account_name: str, zone_name: str) -> None:
    account = find_account(config, account_name)
    zone = find_zone(account, zone_name)
    source_name = zone.get("spotifySourceName") or zone["displayName"]
    spotify_entity_id = account["entityId"]
    alexa_entity_ids = config["alexaSwitchingDeviceIds"]

    print(f"1. [try] select_source({spotify_entity_id}, '{source_name}')")
    client.call_service("media_player", "select_source", {"entity_id": spotify_entity_id, "source": source_name})
    confirmed = wait_for_source_confirmed(client, spotify_entity_id, source_name)

    if not confirmed:
        print(f"2. [detect] no change — {zone['displayName']} isn't on {account['displayName']}'s account")
        print(f"3. [move] switching {zone['displayName']} to {account['displayName']} via Alexa {alexa_entity_ids}")
        outcome = switch_speaker_to_account(client, alexa_entity_ids, account["displayName"], zone["displayName"])
        if outcome != "confirmed":
            print(f"FAILED: {outcome}")
            sys.exit(1)

        print(f"4. [retry] select_source({spotify_entity_id}, '{source_name}')")
        client.call_service("media_player", "select_source", {"entity_id": spotify_entity_id, "source": source_name})
        confirmed = wait_for_source_confirmed(client, spotify_entity_id, source_name, timeout_seconds=10)

    print("SUCCESS" if confirmed else "FAILED: select_source never confirmed")
    sys.exit(0 if confirmed else 1)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--config", type=Path, default=CONFIG_PATH, help="App config to read accounts from")
    subparsers = parser.add_subparsers(dest="command", required=True)

    status_parser = subparsers.add_parser("status", help="Show current state of Spotify accounts and zones.")
    status_parser.add_argument("--account", help="Only show this account (Jamie/Morgan).")

    play_parser = subparsers.add_parser("play-on", help="Full flow: try, detect, move via Alexa, retry.")
    play_parser.add_argument("account")
    play_parser.add_argument("zone")

    args = parser.parse_args()

    env = load_env()
    client = HAClient(require(env, "HA_URL"), require(env, "HA_TOKEN"))
    config = load_music_config(args.config)

    if args.command == "status":
        cmd_status(client, config, args.account)
    elif args.command == "play-on":
        cmd_play_on(client, config, args.account, args.zone)


if __name__ == "__main__":
    main()
