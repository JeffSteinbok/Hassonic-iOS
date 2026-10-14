# Configuration

One file configures the app: dashboard pages, media accounts and zones, and
how to claim a speaker for an account. It lives at
`/local/hassonic.yaml` on Home Assistant, with `Hassonic/Config.yaml`
bundled as a fallback.

## Set it up in Home Assistant

The app reads one file from Home Assistant's `www` folder, which Home Assistant
serves at `/local/`.

1. **Open your Home Assistant config folder.** Use whichever you have:
   - the **File editor** or **Studio Code Server** add-on (Settings → Add-ons),
   - the **Samba share** add-on, then `smb://<home-assistant>/config` in Finder,
   - or SSH (the **Terminal & SSH** add-on): it's `/config`.
2. **Create a `www` folder** next to `configuration.yaml` if there isn't one.
3. **Restart Home Assistant if you just created `www`** (Settings → System →
   Restart). It only serves `/local/` for a folder that existed when it
   started; skipping this is the usual reason the app says it got "a web page
   instead of the dashboard YAML".
4. **Create `www/hassonic.yaml`.** Start from the [example](#shape) below or
   the app's bundled minimal one, `Hassonic/Config.yaml`, and replace the
   entity IDs with yours (Settings → Devices & services → Entities lists them).
5. **Check it's served:** open `https://<your-home-assistant>/local/hassonic.yaml`
   in a browser. You should see the YAML, not a login or error page.
6. **Pull down on any page in Hassonic** to load it (it also reloads on launch
   and when the app comes back to the foreground).

Changes later are just edits to that file followed by a pull-to-refresh; no
restart is needed after the first.

The app keeps the last configuration that fetched and validated. If a new one is
invalid or the server returns an error, it keeps the last good one and shows a
warning naming the problem (see [Troubleshooting](#troubleshooting)). A network
failure keeps it without a warning, since what's on screen is already the good
copy. Until the first successful fetch it uses the bundled `Config.yaml`.

Files in `www` are readable without signing in by anyone who can reach your Home
Assistant. The config holds entity IDs and names, no secrets, but don't put
anything in it you wouldn't want seen.

## Shape

```yaml
version: 1

pages:            # dashboard tabs
  - id: home
    title: Home
    system_icon: house.fill
    sections: [...]

media:            # accounts, speakers, groups, favorites
  accounts:
    - id: alex
      displayName: Alex
      entityId: media_player.alex
      favorites: [...]
      speakers: [...]
      groups: [...]

speakerClaim:     # optional; omit unless several accounts share speakers
  deviceEntityIds: [media_player.kitchen_echo]
  command:      { contentType: custom, phrase: "Switch to {account}'s account" }
  confirmation: { timestampAttribute: last_called_timestamp,
                  responseAttribute:  last_called_response,
                  matches: "in {account}'s account" }
  playback:     { phrase: "Play {content} on Spotify on {speaker}",
                  fallbackContent: "Your Favourites" }
  timings:      { replyTimeoutSeconds: 16, ... }     # optional
```

## Schema

```yaml
version: 1

pages:
  - id: home
    title: Home
    system_icon: house.fill
    sections:
      - title: Downstairs
        cards:
          - type: light
            entity: light.family_room_lights
            title: Family Room Lights

          - type: cover
            entity: cover.awning
            title: Awning

  - id: security
    title: Security
    system_icon: shield.fill
    sections:
      - cards:
          - type: alarm
            entity: alarm_control_panel.home_security_system

          - type: llm_vision_timeline
            title: Security History
```

Page IDs must be unique. Page and section order controls display order. `system_icon`
must be an SF Symbols name.

## Supported cards

| Type | Required fields | Behavior |
|---|---|---|
| `light` | `entity: light.*`; optional `icon` (an SF Symbol, or `torchiere`) | On/off toggle with availability state |
| `cover` | `entity: cover.*` | Open, close, stop and current position; press and hold for 0, 25, 50, 75 or 100% |
| `alarm` | `entity: alarm_control_panel.*` | Status, supported arm modes, and confirmed disarm |
| `llm_vision_timeline` | None | LLM Vision events, images, refresh, and event detail |
| `thermostat` | `entity: climate.*`; optional `outside: weather.*` or `sensor.*`, `compact: true` | Inside temperature, humidity and outside temperature, a Heating/Cooling/Idle pill, the setpoint with − and + (both heat and cool setpoints in Auto), and the modes the thermostat offers (Heat, Cool, Auto, Off). − and + step to whole degrees and send once you stop tapping. `compact` draws one row: name, status, − setpoint +. |
| `room` | `image`, `hotspots` (see below) | A picture of the room with a button on each device |
| `people` | None (see below) | Where everyone is, on a map |
| `tv_remote` | `tv`, `box`, or both (see below) | One panel per device, both always on screen. TV: power, volume, mute, round pad, Home, Back, play/pause, number keys. Box: page and channel rockers, pad with OK and A–D, Back, Exit, Guide, Info, its menu key, playback, number keys. |

### `tv_remote`

```yaml
- type: tv_remote
  title: Family Room
  tv:
    kind: samsung
    remote: remote.family_room_samsung_tv
    mediaPlayer: media_player.family_room_samsung_tv
  box:
    kind: xfinity
    remote: remote.xfinity
    favorites:                       # the ★ key's menu
      - { name: ESPN, say: "watch ESPN", icon: sportscourt.fill }
      - { name: Kids movies, say: "show me kids movies" }
```

| Field | Meaning |
|---|---|
| `kind` | `samsung` (the [SamsungTV Smart](https://github.com/ollo69/ha-samsungtv-smart) custom integration, or HA's built-in [Samsung Smart TV](https://www.home-assistant.io/integrations/samsungtv) one; both take the same key codes) or `xfinity` (the [xfinity_remote](https://github.com/JeffSteinbok/hass-xfinityremote) custom integration). It decides how each key is spelled in `remote.send_command`. |
| `remote` | That integration's `remote.*` entity. |
| `mediaPlayer` | Optional. For Samsung, play/pause toggles through it; without one the key alternates pause and play. |
| `name` | Optional; the panel's label. Defaults to "Samsung TV" or "Xfinity". |
| `power` | Optional `script.*` the power key runs instead of sending the device's own power command. For a Samsung, whose network remote can turn it off but not on, point it at a script that sends the TV's IR power code through an IR blaster such as a Broadlink. |
| `favorites` | Optional, `xfinity` only. Saved voice commands, offered by the ★ key beside the box panel's voice key: each a `name` for the menu, what to `say`, and an optional SF Symbol `icon`. |

Each device gets its own panel and its keys always go to that device: the `tv`
panel is drawn like the Samsung remote, the `box` panel like the X1. Either can
be left out. The 123 key opens a number pad for that device whose digits send as
you tap them, with Last (previous channel) and Enter.

An `xfinity` box panel has a voice key. Tap it and say what you'd say into the
box's own voice remote ("watch ESPN", "show me comedies"); the words go to the
box through the integration's `xfinity_remote.send_text` once you stop talking.
With `favorites`, a ★ key beside it opens a menu of them.

Each card type is written for one kind of entity or integration: `light`, `cover`,
`alarm` and `people` work with any entity of their domain, while
`thermostat` works with any `climate.*` entity (ecobee, Nest, generic thermostats, …), while `llm_vision_timeline` and `tv_remote` only work with their own integrations. A card you don't list never touches its integration, so none of
them is a requirement of the app.

`title` is optional. Entity-backed cards use the Home Assistant friendly name when no
title is supplied. An unknown future card type renders an unsupported-card placeholder
without preventing the rest of the dashboard from loading.

The configuration is data only. Card behavior and Home Assistant service calls remain
implemented and validated by the app.

Keys are case-sensitive, and a key the app doesn't know is ignored rather than
rejected, by the app and by `validate_config.sh` alike. So a misspelled optional
key (`exclude_signed_in_user` for `excludeSignedInUser`) does nothing; if a
setting seems to have no effect, check its spelling here.

## Rooms

A room is a page with `room: true` holding one `room` card: a picture of the
room with a button on each device, placed where the device is. Rooms don't get
a tab; they open from the Rooms strip on the first page that isn't a room, so
a config needs at least one of those.

```yaml
  - id: kitchen
    title: Kitchen
    system_icon: refrigerator
    room: true
    sections:
      - cards:
          - type: room
            image: /local/rooms/kitchen.png
            hotspots:
              - { entity: light.kitchen_pendants, x: 0.42, y: 0.12 }
              - { entity: water_heater.upper_oven, x: 0.8, y: 0.35, size: large }
            status:
              - { entity: sensor.kitchen_temperature }
              - { entity: sensor.kitchen_air_quality, label: Air }
            actions:
              - { name: All off, icon: power, off: [light.kitchen_pendants] }
```

| Field | Meaning |
|---|---|
| `image` | A path on Home Assistant (`/local/…` is its `www` folder) or a full URL. |
| `hotspots` | One button each: an `entity`, and `x`, `y` for its centre as a fraction (0 to 1) of the picture's width and height. Optional `label` (what VoiceOver reads; defaults to the friendly name), `icon` (an SF Symbol) and `size` (`regular` or `large`). One entity can have several hotspots. |
| `status` | Optional chips above the picture, each a sensor's reading: an `entity` and an optional `label`. |
| `actions` | Optional buttons under the picture. Each has a `name`, an optional `icon`, and entities to turn `on` and `off`, or a `script` to run. |

Lights, fans, switches, input booleans, speakers and covers toggle on a tap;
a long press opens brightness, speed or volume where the device has them. Anything else (an oven, a sensor)
opens its sheet on a tap, so a stray tap can't start an oven.

## The `people` card

A `people` card lists where everyone is, with a map per person. Give it its
own page and it becomes a tab:

```yaml
pages:
  - id: people
    title: People
    system_icon: person.2.fill
    sections:
      - cards:
          - type: people
```

Both options are optional:

| key | default | meaning |
|---|---|---|
| `entities` | every `person.*` entity, name-sorted | an explicit list, shown **in the order given** |
| `excludeSignedInUser` | `true` | drop the person tied to the signed-in HA account |
| `title` | none | a heading above the card |

People with no coordinate still appear, as "Away". Addresses come from the companion app's
`sensor.<device>_geocoded_location`, so a person tracked by something without
one shows their zone instead.

## What has a default and what doesn't

**`timings` is the only defaulted group.** Those five numbers were measured
against vendor latency rather than chosen, and contain nothing about any
household.

**Everything else in `speakerClaim` is required when the block is present** —
`deviceEntityIds`, both phrases, the matcher, the two reply attributes,
`contentType`, `fallbackContent`. Each names a vendor, a language or a
preference. Defaulting them would ship one household's setup as everyone's
fallback and let a missing field inherit it silently, so a partial block is
rejected by name instead:

```
INVALID hassonic.yaml
  missing "playback" at speakerClaim
```

Omit `speakerClaim` entirely to disable the feature — a single-account
household needs none of it.

`media` is optional too; omit it if the music tab is unused.

**`displayName` on an account is not just a label.** It is spoken aloud when
claiming a speaker (`"Switch to {account}'s account"`) and matched against
the reply, so it has to match the account name the voice assistant knows.

## Naming the music provider

Everything underneath is stock `media_player`, so the provider is only ever
presentation. `media.provider` is what stops the app telling a Sonos
household to "start playing something in Spotify":

```yaml
media:
  provider:
    name: Spotify
    urlScheme: "spotify:"      # omit and the open-app buttons disappear
    logoAsset: SpotifyLogo     # omit and no logo is shown
  accounts: [...]
```

Omit the whole block and the app names no provider: no logo, no open-app
button, and generic copy ("Start playing something on this speaker"). Only
`name` is required.

The account-switcher's VoiceOver hint is built from the accounts configured
plus this name.

## Live Activity zone buttons

The speaker Live Activity on the lock screen and in the Dynamic Island has
up to four one-tap zone buttons. Pick them per account with
`liveActivityZones`, in the order you want them:

```yaml
media:
  accounts:
    - id: alex
      ...
      liveActivityZones:
        - media_player.kitchen
        - media_player.living_room
        - media_player.downstairs   # groups are fine too
```

Each entry must be one of that account's enabled speakers or groups that has
a `sourceName`, since the button casts to it. You can list at most four, and
no entry twice. Anything else is rejected by name.

Omit it, and the first four castable zones are used, groups first. A
household with several groups gets only groups that way, which is usually
not what you want on a lock screen.

A listed zone that Home Assistant reports as unavailable is left off the
row rather than replaced, so the buttons never show a zone nobody picked.

## Editing workflow

Three scripts cover the loop. They all validate against the app's real schema first —
`scripts/config-validator` is a SwiftPM executable whose sources symlink
`Hassonic/DashboardConfiguration.swift`, so it cannot drift from what the app
enforces, and it prints the same message the app would show.

### 1. Validate locally

```sh
scripts/validate_config.sh path/to/dashboard.yaml   # defaults to the bundled config
scripts/validate_config.sh -                        # read from stdin
```

Exit status is 0 for a valid file and 1 otherwise. A valid file prints its pages,
sections, and card types, and warns about card types the app does not recognize
(almost always a typo — they render as placeholders). An invalid file prints the
failing key, for example:

```
INVALID dashboard.yaml
  missing "system_icon" at pages[1]
```

The first run builds the package (a few seconds); later runs are instant.

### 2. Deploy to Home Assistant

Home Assistant has no REST API that writes into `config/www`, so the upload needs
either SSH or a mounted config share. Credentials come from the gitignored `.ha.env`
at the repository root:

| Variable | Used for |
|---|---|
| `HA_URL` | Base URL, used to verify the upload |
| `HA_TOKEN` | Long-lived token (optional for `/local`) |
| `HA_SSH_TARGET` | `user@host` for `--via ssh` |
| `HA_SSH_PORT` | SSH port, if not 22 |
| `HA_WWW_DIR` | `www` directory; `/config/www` on the HA host, or a local mount for `--via copy` |

```sh
scripts/deploy_config.py dashboard.yaml              # validate, scp, verify
scripts/deploy_config.py dashboard.yaml --via copy   # write to a mounted HA_WWW_DIR
scripts/deploy_config.py --check                     # validate what is deployed now
```

After uploading, the script re-fetches `/local/hassonic.yaml` and compares
bytes, so a stale or mis-pathed write fails loudly instead of silently.

### 3. Inject into a booted simulator

Fastest way to see a layout change without touching Home Assistant:

```sh
scripts/inject_config.py dashboard.yaml            # validate, inject, relaunch the app
scripts/inject_config.py dashboard.yaml --watch    # ...then reload on every save
scripts/inject_config.py --clear                   # drop back to Home Assistant
```

This writes `Documents/config-override.yaml` into the simulator's app container.
**Debug builds read that file instead of fetching from Home Assistant** and keep using
it across reconnects.
Release builds ignore it entirely. Writing the `hassonic.dashboard.lastKnownGoodYAML`
default directly also works, but the next successful fetch overwrites it, so the override
file is the one that sticks.

#### Live reload

`--watch` re-injects whenever the file changes. Debug builds watch the Documents
directory and reparse in place, so only the first injection relaunches the app — every
save after that redraws the running app, keeping whichever tab you are on.

A save that fails validation is reported and *not* injected, so the last good dashboard
stays on screen and the next save can fix it. An override that parses at inject time but
not in the app leaves the dashboard alone too, and names the problem in the warning
banner. `--clear` while watching is refused; run it afterwards, and the running app falls
back to the cached-or-bundled dashboard the way a fresh launch would.

## Tooling

| command | what it does |
|---|---|
| `scripts/validate_config.sh <file>` | checks a file against the real schema, no device needed |
| `scripts/inject_config.py <file>` | pushes it into a booted simulator and relaunches |
| `scripts/deploy_config.py <file>` | uploads to Home Assistant and verifies by re-fetching |

The validator's sources symlink the app's own config types, so it cannot
drift from what the app accepts.

## Troubleshooting

Parse failures name the offending key and its path, with array indices as `[n]` and
`the top level` for the document root:

| Message | Cause |
|---|---|
| `missing "entity" at pages[0].sections[0].cards[1]` | A required key is absent |
| `version: expected Int, found a value of a different type` | `version: "1"` instead of `version: 1` |
| `pages[0].title: expected a single value, found a value of a different type` | A list or block where a scalar belongs |
| `the top level: The given data was not valid YAML. (8:1: error: scanner: ...)` | YAML syntax, usually a tab used for indentation |
| `Home Assistant returned a web page instead of the dashboard YAML.` | The `/local` route was not registered — Home Assistant was still starting, or the file is not in `www` |

The warning on the dashboard is sticky: it clears only on the next successful fetch,
which happens on the next launch, return to the foreground, or pull-to-refresh.
