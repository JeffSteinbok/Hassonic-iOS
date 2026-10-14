#!/usr/bin/env python3

"""Takes the README's screenshots in a simulator, from a made-up household.

Nothing real is shown: the dashboard is Demo/demo-config.yaml, and the
entities and location history are invented here, timed relative to now so
"Arrived 40 min ago" and today's history read naturally. They go into the
app's container, the app launches in demo mode (HASSONIC_DEMO, Debug
simulator builds only), and each screen is opened by link and captured into
docs/images/.

    scripts/screenshots.py                  # build, install, capture all
    scripts/screenshots.py --skip-build     # reuse the last build
    scripts/screenshots.py --only music     # one screen
"""

import argparse
import json
import shutil
import subprocess
import sys
import tempfile
import time
from datetime import datetime, timedelta, timezone
from pathlib import Path

from PIL import Image, ImageDraw

sys.path.insert(0, str(Path(__file__).resolve().parent))
from build_settings import app_bundle_id  # noqa: E402

REPO = Path(__file__).resolve().parent.parent
DEMO = REPO / "Demo"
OUT = REPO / "docs" / "images"
DERIVED = REPO / "build" / "screenshots"
DEVICE = "iPhone 17 Pro"

# Seattle, around a made-up house near the Space Needle.
HOME = (47.6205, -122.3493)
WORK = (47.6097, -122.3331)
PARK = (47.6806, -122.3290)

# (file name, link to open, person whose history sheet opens)
SCREENS = [
    ("home", "hassonic://home", None),
    ("room", "hassonic://living_room", None),
    ("music", "hassonic://music", None),
    ("remote", "hassonic://remote", None),
    ("security", "hassonic://security", None),
    ("people", "hassonic://people", None),
    ("history", "hassonic://people", "person.sam"),
]


def run(*args, capture=False):
    result = subprocess.run(args, check=True, text=True, capture_output=capture)
    return result.stdout.strip() if capture else None


def stamp(when: datetime) -> str:
    return when.astimezone(timezone.utc).isoformat()


def state(entity_id, value, attributes=None, changed=None, updated=None):
    changed = changed or datetime.now(timezone.utc) - timedelta(hours=3)
    return {
        "entity_id": entity_id,
        "state": value,
        "attributes": attributes or {},
        "last_changed": stamp(changed),
        "last_updated": stamp(updated or changed),
    }


def entities(now: datetime, album_art: str) -> list:
    light = lambda entity_id, name, on, modes=("brightness",): state(  # noqa: E731
        entity_id, "on" if on else "off",
        {"friendly_name": name, "supported_color_modes": list(modes), "brightness": 200 if on else None})
    speaker = lambda entity_id, name, value, volume: state(  # noqa: E731
        entity_id, value, {"friendly_name": name, "volume_level": volume, "is_volume_muted": False})
    return [
        light("light.porch_lights", "Porch Lights", True, ("onoff",)),
        light("light.living_room_floor_lamps", "Living Room Floor Lamps", True),
        light("light.living_room_ceiling", "Living Room Ceiling", False),
        light("light.living_room_table_lamps", "Living Room Table Lamps", True),
        state("climate.thermostat", "heat_cool", {
            "friendly_name": "Thermostat", "current_temperature": 70, "current_humidity": 45,
            "target_temp_low": 68, "target_temp_high": 74, "hvac_action": "idle",
            "hvac_modes": ["off", "heat", "cool", "heat_cool"], "min_temp": 45, "max_temp": 92,
        }),
        state("sensor.outdoor_temperature", "61", {"friendly_name": "Outdoor Temperature", "unit_of_measurement": "°F"}),
        state("sensor.living_room_temperature", "71", {"unit_of_measurement": "°F"}),
        state("sensor.living_room_humidity", "44", {"unit_of_measurement": "%"}),
        state("cover.awning", "open", {"friendly_name": "Awning", "current_position": 100, "supported_features": 15}),
        state("alarm_control_panel.home_alarm", "armed_home", {
            "friendly_name": "Home Alarm", "supported_features": 63, "code_arm_required": False}),
        state("media_player.living_room_tv", "on", {
            "friendly_name": "Living Room TV", "source": "TV/HDMI", "source_list": ["TV/HDMI", "Netflix", "YouTube"]}),
        state("remote.living_room_tv", "on", {"friendly_name": "Living Room TV"}),
        state("remote.cable_box", "on", {"friendly_name": "Cable Box"}),
        state("media_player.spotify_alex", "playing", {
            "friendly_name": "Spotify Alex", "source": "Kitchen",
            "source_list": ["Kitchen", "Living Room", "Office", "Patio", "Downstairs"],
            "media_title": "Golden Hour", "media_artist": "The Lanterns", "media_album_name": "Long Light",
            "media_content_id": "demo:track:1", "entity_picture": album_art,
            "media_duration": 214, "media_position": 87, "media_position_updated_at": stamp(now),
            "volume_level": 0.45,
        }),
        speaker("media_player.kitchen_speaker", "Kitchen", "playing", 0.45),
        speaker("media_player.living_room_speaker", "Living Room", "idle", 0.3),
        speaker("media_player.office_speaker", "Office", "idle", 0.25),
        speaker("media_player.patio_speaker", "Patio", "off", 0.5),
        speaker("media_player.downstairs", "Downstairs", "idle", 0.4),
        state("zone.home", "2", {"friendly_name": "Home", "latitude": HOME[0], "longitude": HOME[1], "radius": 100}),
        state("zone.work", "1", {"friendly_name": "Work", "latitude": WORK[0], "longitude": WORK[1], "radius": 150}),
        state("person.alex", "home", {
            "friendly_name": "Alex Rivera", "latitude": HOME[0], "longitude": HOME[1],
            "source": "device_tracker.alexs_iphone"}, changed=now - timedelta(hours=2, minutes=10)),
        state("person.sam", "Work", {
            "friendly_name": "Sam Rivera", "latitude": WORK[0], "longitude": WORK[1],
            "source": "device_tracker.sams_iphone"}, changed=now - timedelta(hours=7, minutes=25)),
        state("sensor.sams_iphone_geocoded_location", "400 Pine St\nSeattle WA 98101\nUnited States"),
        state("person.riley", "not_home", {
            "friendly_name": "Riley Rivera", "latitude": PARK[0], "longitude": PARK[1],
            "source": "device_tracker.rileys_iphone"}, changed=now - timedelta(minutes=40)),
        state("sensor.rileys_iphone_geocoded_location", "7201 E Green Lake Dr N\nSeattle WA 98115\nUnited States"),
        state("sensor.rileys_iphone_activity", "Walking"),
    ]


def history(now: datetime) -> dict:
    """Sam's day: home, a commute, work, and the start of the trip home."""
    def along(start, end, steps):
        return [(start[0] + (end[0] - start[0]) * i / steps + (0.002 if 0 < i < steps else 0),
                 start[1] + (end[1] - start[1]) * i / steps) for i in range(steps + 1)]

    leave = now - timedelta(hours=8, minutes=5)
    arrive = leave + timedelta(minutes=40)
    records = [state("person.sam", "home", {"latitude": HOME[0], "longitude": HOME[1]},
                     changed=now - timedelta(days=1))]
    for i, (lat, lon) in enumerate(along(HOME, WORK, 6)[1:-1]):
        records.append(state("person.sam", "not_home", {"latitude": lat, "longitude": lon},
                             changed=leave, updated=leave + timedelta(minutes=6 * i)))
    records.append(state("person.sam", "Work", {"latitude": WORK[0], "longitude": WORK[1]}, changed=arrive))
    lunch = arrive + timedelta(hours=3, minutes=30)
    records.append(state("person.sam", "not_home", {"latitude": 47.6062, "longitude": -122.3321}, changed=lunch))
    records.append(state("person.sam", "Work", {"latitude": WORK[0], "longitude": WORK[1]},
                         changed=lunch + timedelta(minutes=45)))
    return {"person.sam": records}


def album_art(path: Path):
    """A plain gradient square, standing in for a record sleeve."""
    size = 600
    image = Image.new("RGB", (size, size))
    draw = ImageDraw.Draw(image)
    for y in range(size):
        t = y / size
        draw.line([(0, y), (size, y)], fill=(int(250 - 90 * t), int(170 - 90 * t), int(90 + 60 * t)))
    draw.ellipse([150, 150, 450, 450], fill=(255, 226, 160))
    image.save(path)


def build(device_id):
    run("xcodegen", "generate")
    run("xcodebuild", "-project", "Hassonic.xcodeproj", "-scheme", "Hassonic", "-configuration", "Debug",
        "-destination", f"id={device_id}", "-derivedDataPath", str(DERIVED), "-quiet", "build")


def simulator() -> str:
    devices = json.loads(run("xcrun", "simctl", "list", "devices", "available", "-j", capture=True))["devices"]
    for runtime in sorted(devices, reverse=True):
        for device in devices[runtime]:
            # A duplicated simulator is named "iPhone 17 Pro (2)".
            if device["name"] == DEVICE or device["name"].startswith(DEVICE + " ("):
                return device["udid"]
    raise SystemExit(f"No {DEVICE} simulator")


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--skip-build", action="store_true")
    parser.add_argument("--only", help="One screen by name: " + ", ".join(name for name, _, _ in SCREENS))
    args = parser.parse_args()

    device = simulator()
    subprocess.run(["xcrun", "simctl", "boot", device], capture_output=True)
    run("xcrun", "simctl", "bootstatus", device)
    if not args.skip_build:
        build(device)
    bundle = app_bundle_id("Debug")
    run("xcrun", "simctl", "install", device, str(DERIVED / "Build/Products/Debug-iphonesimulator/Hassonic.app"))

    documents = Path(run("xcrun", "simctl", "get_app_container", device, bundle, "data", capture=True)) / "Documents"
    demo = documents / "demo"
    demo.mkdir(parents=True, exist_ok=True)
    shutil.copy(DEMO / "living-room.png", demo / "living-room.png")
    album_art(demo / "album.png")

    now = datetime.now(timezone.utc)
    (demo / "demo-entities.json").write_text(json.dumps(entities(now, (demo / "album.png").as_uri())))
    (demo / "demo-history.json").write_text(json.dumps(history(now)))
    config = (DEMO / "demo-config.yaml").read_text().replace("{{DEMO}}", demo.as_uri())
    (documents / "config-override.yaml").write_text(config)

    # A clean status bar: 9:41, full signal and battery.
    run("xcrun", "simctl", "status_bar", device, "override", "--time", "9:41", "--batteryState", "charged",
        "--batteryLevel", "100", "--cellularBars", "4", "--wifiBars", "3")
    run("xcrun", "simctl", "ui", device, "appearance", "light")

    OUT.mkdir(parents=True, exist_ok=True)
    for name, link, history_for in SCREENS:
        if args.only and name != args.only:
            continue
        subprocess.run(["xcrun", "simctl", "terminate", device, bundle], capture_output=True)
        environment = {"SIMCTL_CHILD_HASSONIC_DEMO": str(demo), "SIMCTL_CHILD_HASSONIC_OPEN_URL": link}
        if history_for:
            environment["SIMCTL_CHILD_HASSONIC_OPEN_HISTORY"] = history_for
        subprocess.run(["xcrun", "simctl", "launch", device, bundle], check=True, capture_output=True,
                       env={**__import__("os").environ, **environment})
        time.sleep(6)
        path = OUT / f"{name}.png"
        # The simulator service may not write into a protected folder like
        # ~/Documents, so it captures to a temp file that's then moved in.
        with tempfile.TemporaryDirectory() as scratch:
            raw = Path(scratch) / "shot.png"
            subprocess.run(["xcrun", "simctl", "io", device, "screenshot", str(raw)], check=True, capture_output=True)
            # Half size: plenty for a README, a fraction of the bytes.
            with Image.open(raw) as shot:
                shot.convert("RGB").resize((shot.width // 2, shot.height // 2), Image.LANCZOS).save(path, optimize=True)
        print(f"captured {path.relative_to(REPO)}")

    subprocess.run(["xcrun", "simctl", "terminate", device, bundle], capture_output=True)
    run("xcrun", "simctl", "status_bar", device, "clear")
    (documents / "config-override.yaml").unlink(missing_ok=True)


if __name__ == "__main__":
    main()
