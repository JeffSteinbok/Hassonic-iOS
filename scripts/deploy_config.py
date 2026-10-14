#!/usr/bin/env python3

"""Validate a dashboard YAML file and publish it to Home Assistant's www folder.

Home Assistant has no REST API that writes into `config/www`, so the upload
itself goes over SSH (the Advanced SSH & Web Terminal add-on) or through a
locally mounted config share (Samba). Either way the file is validated against
the app's schema first and re-fetched over HTTPS afterwards to prove the app
will see exactly the bytes that were pushed.
"""

import argparse
import shutil
import subprocess
import urllib.error
import urllib.request
from pathlib import Path

from build_settings import xcconfig_value
from ha_env import REPO_ROOT, load_env, require


# What the app fetches: CONFIG_NAME from Config/Base.xcconfig (or your
# Local.xcconfig). --dev deploys the Debug app's file instead.
REMOTE_NAME = f"{xcconfig_value('CONFIG_NAME')}.yaml"
VALIDATOR = REPO_ROOT / "scripts" / "validate_config.sh"


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "file",
        nargs="?",
        type=Path,
        default=REPO_ROOT / "Hassonic" / "Config.yaml",
        help="Dashboard YAML to deploy (default: the bundled config).",
    )
    parser.add_argument(
        "--via",
        choices=("ssh", "copy"),
        default="ssh",
        help="ssh: scp to HA_SSH_TARGET. copy: write to HA_WWW_DIR on this machine.",
    )
    parser.add_argument(
        "--dev",
        action="store_true",
        help="Deploy as the Dev app's file, <CONFIG_NAME>-dev.yaml.",
    )
    parser.add_argument(
        "--check",
        action="store_true",
        help="Only fetch and validate what is already deployed; upload nothing.",
    )
    parser.add_argument(
        "--skip-validate",
        action="store_true",
        help="Skip the local schema check (not recommended).",
    )
    return parser.parse_args()


def validate(path: Path) -> None:
    result = subprocess.run([str(VALIDATOR), str(path)])
    if result.returncode != 0:
        raise SystemExit(f"{path} does not match the dashboard schema; nothing was deployed")


def fetch_deployed(base_url: str, token: str | None) -> bytes:
    request = urllib.request.Request(f"{base_url.rstrip('/')}/local/{REMOTE_NAME}")
    if token:
        request.add_header("Authorization", f"Bearer {token}")
    try:
        with urllib.request.urlopen(request, timeout=30) as response:
            return response.read()
    except urllib.error.HTTPError as error:
        raise SystemExit(f"Home Assistant returned HTTP {error.code} for /local/{REMOTE_NAME}")
    except urllib.error.URLError as error:
        raise SystemExit(f"Could not reach Home Assistant: {error.reason}")


def upload_over_ssh(env: dict[str, str], path: Path) -> None:
    target = require(env, "HA_SSH_TARGET")
    www_dir = env.get("HA_WWW_DIR", "/config/www")
    port = env.get("HA_SSH_PORT")

    command = ["scp"]
    if port:
        command += ["-P", port]
    command += [str(path), f"{target}:{www_dir.rstrip('/')}/{REMOTE_NAME}"]

    if subprocess.run(command).returncode != 0:
        raise SystemExit("scp failed; check HA_SSH_TARGET / HA_SSH_PORT / HA_WWW_DIR")


def upload_by_copy(env: dict[str, str], path: Path) -> None:
    www_dir = Path(require(env, "HA_WWW_DIR"))
    if not www_dir.is_dir():
        raise SystemExit(f"HA_WWW_DIR is not a directory on this machine: {www_dir}")
    shutil.copyfile(path, www_dir / REMOTE_NAME)


def main() -> None:
    global REMOTE_NAME
    args = parse_args()
    if args.dev:
        REMOTE_NAME = REMOTE_NAME.removesuffix(".yaml") + "-dev.yaml"
    env = load_env()
    base_url = require(env, "HA_URL")
    token = env.get("HA_TOKEN")

    if args.check:
        deployed = fetch_deployed(base_url, token)
        scratch = REPO_ROOT / "scripts" / ".deployed-dashboard.yaml"
        scratch.write_bytes(deployed)
        try:
            validate(scratch)
            print(f"Deployed /local/{REMOTE_NAME} is valid ({len(deployed)} bytes)")
        finally:
            scratch.unlink(missing_ok=True)
        return

    if not args.file.is_file():
        raise SystemExit(f"{args.file} does not exist")
    if not args.skip_validate:
        validate(args.file)

    if args.via == "ssh":
        upload_over_ssh(env, args.file)
    else:
        upload_by_copy(env, args.file)

    expected = args.file.read_bytes()
    deployed = fetch_deployed(base_url, token)
    if deployed != expected:
        raise SystemExit(
            f"Uploaded {len(expected)} bytes but /local/{REMOTE_NAME} serves {len(deployed)}; "
            "Home Assistant may be caching or the www path may be wrong"
        )

    print(f"Deployed {args.file.name} -> /local/{REMOTE_NAME} ({len(expected)} bytes, verified)")


if __name__ == "__main__":
    main()
