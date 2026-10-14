#!/usr/bin/env python3

"""Push a dashboard YAML straight into a booted simulator and relaunch the app.

The file lands at `Documents/config-override.yaml` inside the app container,
which debug builds read instead of fetching from Home Assistant. Unlike writing
the UserDefaults cache key directly, the override survives the refresh that runs
as soon as the app reconnects, so the dashboard stays exactly as edited.

`--watch` re-injects on every save. Debug builds watch the Documents directory
and reload in place, so only the first injection relaunches the app.
"""

import argparse
import builtins
import functools
import os
import subprocess
import sys
import time
from pathlib import Path

from build_settings import app_bundle_id
from ha_env import REPO_ROOT


# Simulator runs are Debug builds, which install as the .dev app.
BUNDLE_ID = app_bundle_id("Debug")
OVERRIDE_NAME = "config-override.yaml"
VALIDATOR = REPO_ROOT / "scripts" / "validate_config.sh"


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "file",
        nargs="?",
        type=Path,
        default=REPO_ROOT / "Hassonic" / "Config.yaml",
        help="Dashboard YAML to inject (default: the bundled config).",
    )
    parser.add_argument(
        "--device",
        default="booted",
        help="Simulator UDID or 'booted' (default).",
    )
    parser.add_argument(
        "--clear",
        action="store_true",
        help="Remove the override so the app goes back to Home Assistant.",
    )
    parser.add_argument(
        "--no-relaunch",
        action="store_true",
        help="Leave the app running; the override applies on its next launch.",
    )
    parser.add_argument(
        "--watch",
        action="store_true",
        help="Re-inject whenever the file changes, without relaunching again.",
    )
    parser.add_argument(
        "--poll",
        type=float,
        default=0.5,
        metavar="SECONDS",
        help="How often --watch checks the file for changes (default: 0.5).",
    )
    return parser.parse_args()


def simctl(*arguments: str, capture: bool = False) -> str:
    result = subprocess.run(
        ["xcrun", "simctl", *arguments],
        capture_output=capture,
        text=True,
    )
    if result.returncode != 0:
        message = (result.stderr or "").strip() or f"simctl {arguments[0]} failed"
        raise SystemExit(message)
    return (result.stdout or "").strip()


def app_container(device: str) -> Path:
    return Path(simctl("get_app_container", device, BUNDLE_ID, "data", capture=True))


class ValidatorUnavailable(RuntimeError):
    """The validator itself could not run — distinct from a bad config."""


def is_valid(path: Path) -> bool:
    """True if the file matches the schema.

    Raises ValidatorUnavailable when the validator could not be built or run.
    The two used to be indistinguishable: a broken build reported the config
    as invalid and sent you looking at the wrong file.
    """
    result = subprocess.run([str(VALIDATOR), str(path)], capture_output=True, text=True)
    output = (result.stdout or "") + (result.stderr or "")
    if result.returncode == 0:
        print(result.stdout, end="")
        return True
    # The validator prints "OK <file>" or "INVALID <file>" on a verdict;
    # anything else means it never got as far as reading the config.
    if "INVALID" in output:
        print(output, end="")
        return False
    raise ValidatorUnavailable(output.strip() or f"{VALIDATOR} exited {result.returncode}")


def inject(source: Path, override: Path) -> None:
    override.parent.mkdir(parents=True, exist_ok=True)
    # Replace rather than overwrite in place: the app watches the containing
    # directory, and a truncating write would let it read a half-written file.
    partial = override.with_name(override.name + ".partial")
    partial.write_bytes(source.read_bytes())
    os.replace(partial, override)


def watch(source: Path, override: Path, interval: float) -> None:
    # The validator writes straight to the terminal, so unflushed prints here
    # would show up out of order once the output is piped to anything.
    print = functools.partial(builtins.print, flush=True)

    print(f"Watching {source} — edit and save to reload, Ctrl-C to stop")
    stamp = modified_at(source)
    while True:
        time.sleep(interval)
        latest = modified_at(source)
        if latest == stamp:
            continue
        stamp = latest
        if latest is None:
            print(f"{source.name} disappeared; still watching")
        else:
            try:
                valid = is_valid(source)
            except ValidatorUnavailable as error:
                print(f"could not check {source.name}: {error}", file=sys.stderr)
                continue
            if valid:
                inject(source, override)
                print(f"Reloaded {source.name}")
            else:
                print(f"{source.name} does not match the schema; fix it and save again")


def modified_at(path: Path) -> int | None:
    try:
        return path.stat().st_mtime_ns
    except FileNotFoundError:
        return None


def relaunch(device: str) -> None:
    # terminate fails when the app is not running, which is fine here.
    subprocess.run(
        ["xcrun", "simctl", "terminate", device, BUNDLE_ID],
        capture_output=True,
        text=True,
    )
    simctl("launch", device, BUNDLE_ID, capture=True)


def main() -> None:
    args = parse_args()
    override = app_container(args.device) / "Documents" / OVERRIDE_NAME

    if args.clear:
        if args.watch:
            raise SystemExit("--clear and --watch do the opposite of each other")
        override.unlink(missing_ok=True)
        print(f"Removed {OVERRIDE_NAME}; the app will fetch from Home Assistant again")
    else:
        if not args.file.is_file():
            raise SystemExit(f"{args.file} does not exist")
        try:
            valid = is_valid(args.file)
        except ValidatorUnavailable as error:
            raise SystemExit(
                f"could not check {args.file}: the validator did not run.\n{error}\n"
                f"Nothing was injected. This is a problem with the validator, not your config — "
                f"try: rm -rf {VALIDATOR.parent / 'config-validator' / '.build'}"
            )
        if not valid:
            raise SystemExit(f"{args.file} does not match the schema; nothing was injected")
        inject(args.file, override)
        print(f"Injected {args.file.name} as {OVERRIDE_NAME}")

    # The relaunch is what gets a stale build of the app onto the new override;
    # from then on the app reloads in place, so --watch never relaunches again.
    if not args.no_relaunch:
        relaunch(args.device)

    if args.watch:
        try:
            watch(args.file, override, args.poll)
        except KeyboardInterrupt:
            print()


if __name__ == "__main__":
    main()
