#!/usr/bin/env python3
"""Add an alternate app icon that users can pick in Settings → App Icon.

    scripts/add_app_icon.py "Waveform House" path/to/icon-1024.png

Creates two asset-catalog entries from one 1024×1024 PNG:

- `AppIcon-<Slug>.appiconset`  the icon iOS uses on the home screen. Xcode
  ships every AppIcon-* set as an alternate (ASSETCATALOG_COMPILER_INCLUDE_
  ALL_APPICON_ASSETS in project.yml) and lists it in the built Info.plist.
- `AppIconPreview-<Slug>.imageset`  the same art for the picker to draw,
  since an app icon set can't be loaded as an image at runtime.
- `AppMark-<Slug>.imageset` in the widget extension  a small copy for the
  Live Activity and Dynamic Island, which can't draw large images.

With `--mark` (the art on a transparent background) and `--top`, plus
optionally `--bottom` and `--light-text`, it also adds:

- `AppIconMark-<Slug>.imageset` and an entry in Hassonic/AppIconThemes.json
  so the splash and connection-failed screens fill with the icon's colors and
  draw the bare mark, instead of the icon as a tile.

The picker shows only the art; the name (dashes as spaces) is what
VoiceOver reads, so keep it descriptive and free of other brands' names. Run `xcodegen generate`
afterwards only if project.yml changed; new assets need no project edit.
Remove an icon by deleting its folders and its AppIconThemes.json entry.
"""
import argparse
import json
import re
import shutil
import subprocess
import struct
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
ASSETS = ROOT / "Hassonic" / "Assets.xcassets"
WIDGET_ASSETS = ROOT / "HassonicWidgets" / "Assets.xcassets"
THEMES = ROOT / "Hassonic" / "AppIconThemes.json"
HEX = re.compile(r"^#[0-9A-Fa-f]{6}$")


def png_size(path: Path) -> tuple[int, int]:
    with path.open("rb") as f:
        header = f.read(24)
    if header[:8] != b"\x89PNG\r\n\x1a\n":
        sys.exit(f"{path} is not a PNG")
    return struct.unpack(">II", header[16:24])


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("name", help='Display name, e.g. "Waveform House"')
    parser.add_argument("png", type=Path, help="1024x1024 PNG, no transparency")
    parser.add_argument("--force", action="store_true", help="Replace an existing icon with this name")
    parser.add_argument("--mark", type=Path, help="The art alone on a transparent background, square PNG")
    parser.add_argument("--top", help="Theme background color, #RRGGBB (needs --mark)")
    parser.add_argument("--bottom", help="Gradient end color, #RRGGBB; defaults to --top")
    parser.add_argument("--light-text", action="store_true", help="The background is dark: use light text")
    args = parser.parse_args()
    if bool(args.mark) != bool(args.top):
        sys.exit("--mark and --top go together: a mark needs a theme to sit on.")
    for color in filter(None, (args.top, args.bottom)):
        if not HEX.match(color):
            sys.exit(f"{color} isn't #RRGGBB.")

    slug = re.sub(r"[^A-Za-z0-9]+", "-", args.name.strip()).strip("-")
    if not slug:
        sys.exit("The name needs at least one letter or digit.")
    if png_size(args.png) != (1024, 1024):
        sys.exit(f"{args.png} is {png_size(args.png)}, not 1024x1024.")

    icon_dir = ASSETS / f"AppIcon-{slug}.appiconset"
    preview_dir = ASSETS / f"AppIconPreview-{slug}.imageset"
    mark_dir = WIDGET_ASSETS / f"AppMark-{slug}.imageset"
    theme_mark_dir = ASSETS / f"AppIconMark-{slug}.imageset"
    dirs = [icon_dir, preview_dir, mark_dir] + ([theme_mark_dir] if args.mark else [])
    for d in dirs:
        if d.exists():
            if not args.force:
                sys.exit(f"{d.name} already exists; pass --force to replace it.")
            shutil.rmtree(d)
        d.mkdir()

    shutil.copyfile(args.png, icon_dir / "icon.png")
    (icon_dir / "Contents.json").write_text(json.dumps({
        "images": [{"filename": "icon.png", "idiom": "universal", "platform": "ios", "size": "1024x1024"}],
        "info": {"author": "xcode", "version": 1},
    }, indent=2) + "\n")

    shutil.copyfile(args.png, preview_dir / "icon.png")
    (preview_dir / "Contents.json").write_text(json.dumps({
        "images": [{"filename": "icon.png", "idiom": "universal"}],
        "info": {"author": "xcode", "version": 1},
    }, indent=2) + "\n")

    images = []
    for scale, suffix in ((1, ""), (2, "@2x"), (3, "@3x")):
        filename = f"AppMark{suffix}.png"
        subprocess.run(["sips", "-z", str(32 * scale), str(32 * scale), str(args.png), "--out", str(mark_dir / filename)],
                       check=True, capture_output=True)
        images.append({"filename": filename, "idiom": "universal", "scale": f"{scale}x"})
    (mark_dir / "Contents.json").write_text(json.dumps({
        "images": images,
        "info": {"author": "xcode", "version": 1},
    }, indent=2) + "\n")

    if args.mark:
        subprocess.run(["sips", "-z", "512", "512", str(args.mark), "--out", str(theme_mark_dir / "mark.png")],
                       check=True, capture_output=True)
        (theme_mark_dir / "Contents.json").write_text(json.dumps({
            "images": [{"filename": "mark.png", "idiom": "universal"}],
            "info": {"author": "xcode", "version": 1},
        }, indent=2) + "\n")
        themes = json.loads(THEMES.read_text()) if THEMES.exists() else {}
        themes[slug] = {"top": args.top.upper(), "bottom": (args.bottom or args.top).upper(),
                        "text": "light" if args.light_text else "dark"}
        THEMES.write_text("{\n" + ",\n".join(
            f'  "{k}": {json.dumps(v, separators=(", ", ": ")).replace("{", "{ ").replace("}", " }")}'
            for k, v in themes.items()) + "\n}\n")

    print(f"Added {', '.join(d.name for d in dirs)}. Rebuild to see it in Settings → App Icon.")


if __name__ == "__main__":
    main()
