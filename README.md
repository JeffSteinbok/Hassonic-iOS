# Hassonic

A native iOS app for [Home Assistant](https://www.home-assistant.io/). It talks
to your Home Assistant server over its WebSocket API and gives you a focused set
of controls: which speakers your music plays on and how loud, a Lock Screen Live
Activity for switching speakers, and pages of lights, covers, TV remotes and
security that you lay out yourself in one YAML file.

---

## Features

| | |
|---|---|
| **Music** | Now Playing, favorites, and per-speaker volume for each media account. Pick which speaker or group to play on; a group's volume moves all its speakers together. |
| **Live Activity** | While music plays: the active zone, up to four zone buttons, and a volume bar on the Lock Screen and in the Dynamic Island. See [Live Activity](docs/live-activity.md). |
| **Pages** | Tabs built from the config: lights, covers, thermostats, alarm panel, security timeline, people, and TV remotes. More than five tabs go under iOS's standard **More** tab. |
| **CarPlay** | Where everyone is: household `person.*` entities on a list and a map. Simulator only: device builds can't carry the CarPlay entitlement. See [CarPlay](docs/carplay.md). |
| **App shell** | Splash while connecting, a connection-failed screen with Try Again, a menu with Settings and About, pull-to-refresh to reload the config, and the last tab remembered across launches. |

---

## What it needs

Only Home Assistant is required. Everything else depends on which features you
put in your config — a card you don't list never touches its integration.

### Required

| | |
|---|---|
| **Home Assistant** | Reachable from the phone; any external URL (Nabu Casa or your own) for use away from home. An optional internal URL is used on your home Wi-Fi. |
| **iPhone on iOS 26+** | The minimum, for CarPlay's newer layouts. |
| **`hassonic.yaml`** in your HA `www` folder | The app's config. See [Setting up your config](#setting-up-your-config). A minimal example is bundled as a fallback. |
| **The sign-in page** | Home Assistant checks a static page during OAuth sign-in: [`docs/index.html`](docs/index.html), served by GitHub Pages and named by `HA_OAUTH_CLIENT_ID` in `Config/Base.xcconfig`. It holds no data, but sign-in fails if it's down. |

### Optional, per feature

Each card type is written in code for one integration; whether it appears at all,
and which entity it controls, is config.

| Feature | Needs | Hardcoded to a vendor? |
|---|---|---|
| Music tab, Live Activity | A music service in HA whose account entity lists speakers in `source_list` (Spotify Connect is the one tested), and speakers exposed as `media_player` entities (Echo, Sonos, Google, receivers, …) | No. Playback and volume use stock `media_player` services. The provider name, logo and app link are config. |
| Moving a speaker between accounts | **Alexa Media Player** (HACS) and Echo devices, declared in `speakerClaim` | No. The whole recipe (device, phrase, expected reply, timings) is config. Omit `speakerClaim` to turn it off. See [Spotify and Alexa](docs/SPOTIFY_AND_ALEXA.md). |
| `light`, `cover`, `alarm`, `people`, `thermostat` cards | Any entity of that domain (`climate.*` for the thermostat) | No |
| `llm_vision_timeline` card | **LLM Vision** (HACS) and an AI provider for it | The card is: it reads LLM Vision's timeline API. |
| `tv_remote` card | For each device on it: **SamsungTV Smart** (HACS) or HA's built-in **Samsung Smart TV** integration, or the [`xfinity_remote`](https://github.com/jeffsteinbok/hass-xfinityremote) custom integration | The brands are: each `kind` is one integration's key codes. Which device each key goes to is config. |

Another TV or box brand means another `kind` in code: a table of its key
codes. The layout and routing don't change.

### Libraries

- [**Yams**](https://github.com/jpsim/Yams) — parses the config.
- [**Firebase**](https://github.com/firebase/firebase-ios-sdk) — push
  notifications. Not configured, so inactive; see
  [Push notifications](docs/push-notification-setup.md).

### Who it's for

Home Assistant users comfortable editing a YAML file on their server. The music
tab and Live Activity are the strongest reasons to use it, so the best fit is a
household that already has a music service and its speakers in Home Assistant.

---

## Signing in

1. Launch the app and tap **Get Started**.
2. Enter your Home Assistant URL (and, under Advanced, an optional internal URL
   for home Wi-Fi).
3. Tap **Log in with Home Assistant** and sign in on your server's own login page.

The app gets an access and refresh token through Home Assistant's OAuth flow and
keeps them, with the URLs, in the iOS Keychain only. It renews the access token
silently.

> **Never commit tokens, URLs, or any credential to this repository.**

---

## Setting up your config

Everything the app shows (pages, cards, music accounts and speakers) comes from
one YAML file on your Home Assistant. In short:

1. Open your Home Assistant config folder: the **File editor** or **Studio Code
   Server** add-on, the **Samba share** add-on (`smb://<home-assistant>/config`),
   or SSH (`/config`).
2. Create a `www` folder next to `configuration.yaml` if there isn't one, and
   **restart Home Assistant** if you just made it; it only serves `/local/` for
   a folder that existed at startup.
3. Create `www/hassonic.yaml`. Start from `Hassonic/Config.yaml` or the
   example in [Configuration](docs/configuration.md), using your entity IDs
   (Settings → Devices & services → Entities).
4. Check `https://<your-home-assistant>/local/hassonic.yaml` opens in a
   browser, then pull down on any page in the app.

After that, edit the file and pull to refresh. A file with a mistake doesn't
break the app: it keeps the last good config and shows a warning naming the
key at fault. [Configuration](docs/configuration.md) has the full steps, every
card type, and the tools for validating and deploying from this repo.

---

## Building

| Tool | Version | Install |
|---|---|---|
| Xcode | 26+ | [Mac App Store](https://apps.apple.com/app/xcode/id497799835) |
| XcodeGen | 2.x | `brew install xcodegen` |

The `.xcodeproj` is generated from `project.yml` and not committed.

```bash
git clone https://github.com/JeffSteinbok/Hassonic-iOS.git
cd Hassonic-iOS
xcodegen generate
open Hassonic.xcodeproj
```

That builds and runs in the simulator as `com.example.Hassonic`. To run on a
device, or to ship your own build to TestFlight, give it your own identity:

```bash
cp Config/Local.xcconfig.example Config/Local.xcconfig
```

and set, in `Config/Local.xcconfig` (gitignored):

| Setting | What it is |
|---|---|
| `BUNDLE_ID_PREFIX` | Your reverse-DNS prefix, e.g. `com.yourname`. The app is `<prefix>.Hassonic`, the widget `<prefix>.Hassonic.Widgets`; Debug builds add `.dev` and install beside Release as **Hassonic Dev**. |
| `APP_BUNDLE_ID` | Optional. The whole app ID, if it must be something other than `<prefix>.Hassonic`, e.g. to keep an app you already have in App Store Connect. |
| `DEVELOPMENT_TEAM` | Your Apple Developer team ID. |
| `HA_OAUTH_CLIENT_ID` | Optional. The sign-in page; defaults to this repo's. Host your own copy of `docs/index.html` if you'd rather not depend on it. |

Run `xcodegen generate` again after changing it. `scripts/testflight.sh`
archives and uploads with the same settings.

Push notifications are off unless you add your own
`Hassonic/GoogleService-Info.plist`; see
[Push notifications](docs/push-notification-setup.md).

Command-line build:

```bash
xcodebuild -project Hassonic.xcodeproj -scheme Hassonic \
  -destination 'generic/platform=iOS Simulator' build
```

---

## App icons

Settings → **App Icon** lets the user pick the home-screen icon. To add one,
give it a name and a 1024×1024 PNG with no transparency, plus the art alone on
a transparent background and the icon's background color(s) for its theme:

```bash
scripts/add_app_icon.py "Waveform House" ~/Downloads/waveform-house.png \
  --mark ~/Downloads/waveform-house-mark.png --top "#1A4ED8" --light-text
```

`--bottom` makes the background a top-to-bottom gradient; `--light-text` is for
a dark background. The theme fills the splash and connection-failed screens
with the icon's colors and draws the bare mark on them. Without `--mark` and
`--top`, those screens show the icon as a tile on the plain background.

That creates `AppIcon-Waveform-House.appiconset` (the icon),
`AppIconPreview-Waveform-House.imageset` (what the picker draws) and a small
`AppMark-Waveform-House.imageset` in the widget extension (for the Live
Activity), and with a theme `AppIconMark-Waveform-House.imageset` and an entry
in `Hassonic/AppIconThemes.json`. Rebuild and it appears in the picker;
nothing else to edit. To remove one, delete its folders and its theme entry. iOS shows its own confirmation alert on every change.

The chosen icon shows on the home screen, App Library, Spotlight and
notifications, and the app uses it on the splash, About, the Live Activity and
the Dynamic Island. The App Store and TestFlight always show the primary
`AppIcon`.

---

## Architecture

```
HassonicApp            entry point: root phase (welcome / splash / tabs / failed)
├── HAWebSocketClient      WebSocket connection and entity state; service calls,
│                          select-source and speaker claim in +Services/+SelectSource/+SpeakerClaim
├── AppConfigurationLoader fetches and validates hassonic.yaml, keeps last-known-good
├── AppRouter              tabs, deep links, the Settings/About sheets
├── MusicZonesView         Music tab (NowPlayingCard, FavoritesBar, PlayOnSheet, SpeakerRow)
├── DashboardPageView      config-driven pages and cards
└── ZonesLiveActivityController   starts/updates the Live Activity

HassonicWidgets        Live Activity and Dynamic Island UI (widget extension)
Shared/                    ActivityKit attributes and intents, compiled into both targets
CarPlaySceneDelegate       separate scene; shares HAWebSocketClient.shared
```

- Views share the client, router and loader as `@EnvironmentObject`s.
- The config is fetched from `/local/hassonic.yaml` after connecting, on
  return to the foreground, and on pull-to-refresh. A network failure keeps the
  last good config without a warning; an HTTP or parse error shows one.
- Debug builds can load a config from the app container instead; see
  `scripts/inject_config.py`.

---

## Configuration workflow

| Task | Command |
|---|---|
| Validate a config against the app's real parser | `scripts/validate_config.sh hassonic.yaml` |
| Deploy it to Home Assistant | `python3 scripts/deploy_config.py hassonic.yaml` (needs `HA_SSH_TARGET` in `.ha.env`) |
| Try it in a booted simulator | `python3 scripts/inject_config.py hassonic.yaml` |
| Refresh the sanitized HA entity inventory | `HA_ACCESS_TOKEN=... scripts/export_ha_entities.py --base-url https://example.ui.nabu.casa` |

---

## Testing

```bash
xcodegen generate
xcodebuild test -project Hassonic.xcodeproj -scheme Hassonic \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=latest' \
  -only-testing:HassonicTests
```

Tests need no live Home Assistant. `MockHAClient` conforms to
`HAClientProtocol`, never opens a socket, and records every service call; JSON
fixtures for HA messages live in `HassonicTests/Fixtures/`.

```swift
let mock = MockHAClient()
mock.simulateConnected(entities: MockHAClient.Fixtures.mediaPlayerEntities)
XCTAssertEqual(mock.volumeSetCalls.last?.level, 0.5)
```

---

## Limitations

- One Home Assistant server at a time.
- No in-app config editor; the YAML is edited and deployed by hand.
- CarPlay runs only in the simulator. It needs an Apple-granted entitlement in a
  category a home-automation app is unlikely to get.
- The Live Activity updates only while the app runs; see
  [Live Activity](docs/live-activity.md) for the push-based options.

---

## Contributing

A personal project; focused PRs are welcome. Build and run the tests before opening a
PR, and never commit credentials or private server addresses.
