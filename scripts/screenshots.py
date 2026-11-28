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

# (file name, link to open, extra launch environment: a sheet to open)
SCREENS = [
    ("home", "hassonic://home", {}),
    ("room", "hassonic://living_room", {}),
    ("room-next", "hassonic://family_room", {}),
    ("music", "hassonic://music", {}),
    ("remote", "hassonic://remote", {}),
    ("security", "hassonic://security", {}),
    ("people", "hassonic://people", {}),
    ("history", "hassonic://people", {"HASSONIC_OPEN_HISTORY": "person.sam"}),
    ("room-music", "hassonic://living_room", {"HASSONIC_OPEN_SHEET": "room-music"}),
    ("play-on", "hassonic://music", {"HASSONIC_OPEN_SHEET": "play-on"}),
    ("browse", "hassonic://music", {"HASSONIC_OPEN_SHEET": "browse"}),
    ("browse-playlists", "hassonic://music",
     {"HASSONIC_OPEN_SHEET": "browse", "HASSONIC_BROWSE_AT": "current_user_playlists"}),
    ("browse-artists", "hassonic://music",
     {"HASSONIC_OPEN_SHEET": "browse", "HASSONIC_BROWSE_AT": "current_user_followed_artists"}),
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
        state("media_player.family_room_tv", "on", {
            "friendly_name": "Family Room TV", "source": "TV/HDMI", "source_list": ["TV/HDMI", "Netflix", "YouTube"]}),
        state("remote.family_room_tv", "on", {"friendly_name": "Family Room TV"}),
        state("remote.family_room_box", "on", {"friendly_name": "Family Room Box"}),
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


def album_art(path: Path, wide=False):
    """A plain gradient, standing in for a record sleeve: square, or 16:9 like
    a video thumbnail when `wide`."""
    width, height = (1066, 600) if wide else (600, 600)
    image = Image.new("RGB", (width, height))
    draw = ImageDraw.Draw(image)
    for y in range(height):
        t = y / height
        draw.line([(0, y), (width, y)], fill=(int(250 - 90 * t), int(170 - 90 * t), int(90 + 60 * t)))
    middle = width // 2
    draw.ellipse([middle - 150, 150, middle + 150, 450], fill=(255, 226, 160))
    image.save(path)


def cover(path: Path, top, bottom, size=(600, 600)):
    """A two-tone gradient standing in for a cover. Not square when an
    artist photo or station logo is wanted, to show it isn't cropped."""
    image = Image.new("RGB", size)
    draw = ImageDraw.Draw(image)
    for y in range(size[1]):
        t = y / size[1]
        draw.line([(0, y), (size[0], y)], fill=tuple(int(a + (b - a) * t) for a, b in zip(top, bottom)))
    draw.rectangle([size[0] // 4, size[1] // 4, size[0] * 3 // 4, size[1] * 3 // 4], outline=(255, 255, 255), width=8)
    image.save(path)


def recents(demo: Path) -> list:
    """The Music tab's Recents row: a few made-up albums and playlists."""
    entries = [
        ("Long Light", "Album", (250, 170, 90), (160, 80, 150), (600, 600)),
        ("Morning Coffee", "Playlist", (120, 80, 50), (230, 200, 150), (600, 600)),
        # No art and no icon: a playlist Home Assistant couldn't find art for.
        ("Road Trip", "Playlist", None, None, None),
        ("Harbor Sessions", "Album", (40, 90, 160), (120, 200, 220), (600, 600)),
        ("The Lanterns", "Artist", (60, 60, 70), (200, 160, 90), (900, 600)),
        ("Dinner Jazz", "Playlist", (90, 20, 40), (220, 120, 80), (600, 600)),
    ]
    items = []
    for index, (title, kind, top, bottom, size) in enumerate(entries):
        item = {"contentType": kind.lower(), "contentId": f"demo:{kind.lower()}:{index}", "title": title, "subtitle": kind}
        if size:
            path = demo / f"recent-{index}.png"
            cover(path, top, bottom, size)
            item["thumbnail"] = path.as_uri()
        items.append(item)
    return items


def browse(demo: Path) -> dict:
    """Browse's library, shaped like Spotify's in Home Assistant: folders
    told apart only by their ids, then playlists and artists inside."""
    def folder(content_id, title, children_class):
        return {"title": title, "media_class": "directory", "media_content_type": content_id,
                "media_content_id": content_id, "can_play": False, "can_expand": True,
                "children_media_class": children_class, "thumbnail": None}

    def item(kind, index, title, top=None, bottom=None, size=(600, 600)):
        node = {"title": title, "media_class": kind, "media_content_type": f"spotify://{kind}",
                "media_content_id": f"demo:{kind}:{index}", "can_play": True, "can_expand": True, "thumbnail": None}
        if top:
            path = demo / f"browse-{kind}-{index}.png"
            cover(path, top, bottom, size)
            node["thumbnail"] = path.as_uri()
        return node

    root = {"title": "Spotify", "media_class": "directory", "media_content_type": "spotify://library",
            "media_content_id": "library", "can_play": False, "can_expand": True, "children": [
                folder("current_user_playlists", "Playlists", "playlist"),
                folder("current_user_followed_artists", "Artists", "artist"),
                folder("current_user_saved_albums", "Albums", "album"),
                folder("current_user_saved_tracks", "Liked songs", "track"),
                folder("current_user_saved_shows", "Podcasts", "podcast"),
                folder("current_user_recently_played", "Recently played", "track"),
                folder("current_user_top_artists", "Top Artists", "artist"),
                folder("current_user_top_tracks", "Top Tracks", "track"),
                folder("categories", "Categories", "genre"),
                folder("featured_playlists", "Featured Playlists", "playlist"),
                folder("new_releases", "New Releases", "album"),
            ]}
    playlists = dict(folder("current_user_playlists", "Playlists", "playlist"), children=[
        item("playlist", 1, "Morning Coffee", (120, 80, 50), (230, 200, 150)),
        item("playlist", 2, "Focus", (30, 60, 90), (90, 160, 200)),
        item("playlist", 3, "Dinner Jazz", (90, 20, 40), (220, 120, 80)),
        item("playlist", 4, "Road Trip"),
        item("playlist", 5, "Rainy Day", (70, 80, 100), (170, 180, 200)),
    ])
    artists = dict(folder("current_user_followed_artists", "Artists", "artist"), children=[
        item("artist", 1, "The Lanterns", (60, 60, 70), (200, 160, 90), (900, 600)),
        item("artist", 2, "Harbor Lights", (40, 90, 160), (120, 200, 220)),
        item("artist", 3, "June Avenue"),
        item("artist", 4, "Paper Kites Club", (150, 60, 90), (240, 170, 120)),
    ])
    return {"": root, "current_user_playlists": playlists, "current_user_followed_artists": artists}


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
    parser.add_argument("--appearance", choices=["light", "dark"], default="light")
    parser.add_argument("--no-recents", action="store_true", help="Leave the Music tab's Recents row empty")
    parser.add_argument("--start-volume", metavar="ZONE",
                        help="Show the volume strip a start brings up, for this zone (e.g. media_player.kitchen_speaker)")
    parser.add_argument("--wide-cover", action="store_true", help="Play a 16:9 cover instead of a square one")
    parser.add_argument("--device", help="A simulator's UDID, instead of the first " + DEVICE)
    args = parser.parse_args()

    device = args.device or simulator()
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
    album_art(demo / "album.png", wide=args.wide_cover)

    now = datetime.now(timezone.utc)
    (demo / "demo-entities.json").write_text(json.dumps(entities(now, (demo / "album.png").as_uri())))
    (demo / "demo-history.json").write_text(json.dumps(history(now)))
    (demo / "demo-browse.json").write_text(json.dumps(browse(demo)))
    (demo / "demo-recents.json").write_text(json.dumps([] if args.no_recents else recents(demo)))
    config = (DEMO / "demo-config.yaml").read_text().replace("{{DEMO}}", demo.as_uri())
    (documents / "config-override.yaml").write_text(config)

    # A clean status bar: 9:41, full signal and battery.
    run("xcrun", "simctl", "status_bar", device, "override", "--time", "9:41", "--batteryState", "charged",
        "--batteryLevel", "100", "--cellularBars", "4", "--wifiBars", "3")
    run("xcrun", "simctl", "ui", device, "appearance", args.appearance)
    # A light, with-recents run writes the README's files; any other
    # variant gets its own name beside them.
    suffix = ("-dark" if args.appearance == "dark" else "") + ("-no-recents" if args.no_recents else "") \
        + ("-start-volume" if args.start_volume else "") + ("-wide-cover" if args.wide_cover else "")

    OUT.mkdir(parents=True, exist_ok=True)
    for name, link, extra in SCREENS:
        if args.only and name != args.only:
            continue
        subprocess.run(["xcrun", "simctl", "terminate", device, bundle], capture_output=True)
        environment = {"SIMCTL_CHILD_HASSONIC_DEMO": str(demo), "SIMCTL_CHILD_HASSONIC_OPEN_URL": link}
        environment.update({f"SIMCTL_CHILD_{key}": value for key, value in extra.items()})
        if args.start_volume:
            environment["SIMCTL_CHILD_HASSONIC_DEMO_START_VOLUME"] = args.start_volume
        subprocess.run(["xcrun", "simctl", "launch", device, bundle], check=True, capture_output=True,
                       env={**__import__("os").environ, **environment})
        # A sheet slides up once the page has loaded.
        time.sleep(12 if extra else 6)
        path = OUT / f"{name}{suffix}.png"
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
