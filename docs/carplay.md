# CarPlay: people locations

The CarPlay screen shows where everyone is: a list of Home Assistant
`person.*` entities down the left side — name plus the zone HA reports them
in — and a map on the right with a pin per person. Pins are each person's HA
profile picture, circle-cropped inside a white ring.

## How it's built

The screen is drawn by hand, not assembled from a CarPlay template.

The obvious route was `CPPointOfInterestTemplate` — the one stock template
that pairs a list with a map. It didn't work out: CarPlay owns that
template's layout completely, its rows are a large bold title over a grey
subtitle with heavy padding, and in practice **four people didn't fit on
screen without scrolling**. `CPPointOfInterest` also has no image property,
so profile pictures could only ever appear as map pins, never beside the
names.

Under the navigation entitlement CarPlay instead hands the app a `CPWindow`
to render its own view hierarchy into, with a `CPMapTemplate` supplying the
system chrome on top. That's what this uses, so row height, typography, and
density are all ours to set.

| File | Role |
|------|------|
| `Hassonic/CarPlay/PersonLocation.swift` | Turns an HA entity snapshot into the people list. Pure logic, fully unit-tested. |
| `Hassonic/CarPlay/CarPlaySceneDelegate.swift` | Owns the CarPlay scene: sets up the window, follows `HAWebSocketClient.shared`, supplies the empty-state message. |
| `Hassonic/CarPlay/CarPlayPeopleViewController.swift` | The screen itself — list panel, map, annotations, framing. |
| `Hassonic/CarPlay/PersonRowView.swift` | One compact list row: avatar, name, zone. |
| `Hassonic/CarPlay/PersonPinRenderer.swift` | Draws the circular avatar images — avatar or initials. |
| `Hassonic/CarPlay/PersonAvatarStore.swift` | Fetches and caches HA profile pictures with the bearer token. |
| `Hassonic/HomeAssistant/HAConnectionBootstrapper.swift` | Shared "connect from saved credentials" path used by both the phone UI and CarPlay. |

The CarPlay scene is a *sibling* of the SwiftUI window scene, not a child of
it — CarPlay can launch the app on its own, with the phone UI never shown —
so it can't reach the client through the SwiftUI environment. Both scenes
share `HAWebSocketClient.shared` and the CarPlay delegate kicks off its own
connection attempt on connect rather than assuming the phone UI got there
first.

## Where the coordinates come from

For each `person.*` entity, in order:

1. The entity's own `latitude` / `longitude` attributes (what a companion-app
   device tracker reports).
2. Failing that, the `zone.*` entity matching the person's state — so someone
   tracked only by a router-based tracker still pins at home. Zones are
   matched by friendly name (HA puts the zone's name in the person's state)
   and by entity-id suffix.

A person with neither — typically `not_home` with no GPS — has no pin and is
left off the screen entirely, since a row with no map counterpart would be
misleading.

The state itself becomes the label: `home` → "Home", `not_home` → "Away",
anything else is the zone's own name, shown verbatim.

## The list

Name-sorted and capped at **4** people
(`PersonLocationDirectory.maximumDisplayedPeople`) — raise the constant if
you want more, but four is about what's readable at a glance while driving.

The panel sits over the leading edge of the map and sizes itself to its
content. Its width is 36% of the screen, capped at 330pt, so it doesn't
swallow a third of an ultrawide head unit. Rows are a 40pt avatar beside a
19pt name over a 15pt zone, which fits four comfortably on an 800×480 screen
with room to spare.

CarPlay screens vary widely between head units, so nothing here is a fixed
pixel count — the layout is constraint-driven and the panel caps rather than
scales.

## Profile pictures

A person's `entity_picture` attribute is resolved against the HA base URL
(`resolveHAImageURL`) and fetched with the same bearer token as everything
else. `PersonPinRenderer` circle-crops it, aspect-fill so faces don't squash,
at the car screen's own display scale — 40pt in the list, 44pt as a map
annotation.

Avatars render immediately as the person's initials on a blue disc and swap
to the photo once it arrives. Pictures are cached for the session — someone
moving between zones re-renders the map repeatedly and must not re-download
each time — and a failed fetch is remembered so a broken picture doesn't
retry forever.

## Entitlements, and why this is simulator-only for now

CarPlay is gated on an Apple-granted entitlement. You request one per app
from Apple, in one of their fixed categories (audio, communication,
navigation, parking, EV charging, quick food ordering, fueling, driving
task); Rendering into a `CPWindow` is the navigation category's privilege, so the
project declares `com.apple.developer.carplay-maps`.

A home-automation app is not in any of those categories, so Apple is unlikely
to grant it, and **without the grant no device provisioning profile can carry
the entitlement** — including it in the device build would break automatic
signing outright.

So `project.yml` scopes it to simulator builds, where entitlements aren't
validated against a profile:

```yaml
CODE_SIGN_ENTITLEMENTS: Hassonic/Hassonic.entitlements
CODE_SIGN_ENTITLEMENTS[sdk=iphonesimulator*]: Hassonic/HassonicSimulator.entitlements
```

Device builds keep the original entitlements and simply never get a CarPlay
scene. If Apple ever does grant the entitlement, move the
`com.apple.developer.carplay-maps` key into `Hassonic.entitlements`
and delete the simulator-only file and the conditional setting — nothing else
changes.

The `UIApplicationSceneManifest` in `project.yml` declares the CarPlay scene
for every build. That's harmless without the entitlement — the system just
never creates the scene. It does require
`UIApplicationSupportsMultipleScenes: true`, since CarPlay runs alongside the
phone window; the side effect is that iPad now permits multiple app windows.

## Testing it in the simulator

```bash
xcodegen generate
xcodebuild -project Hassonic.xcodeproj -scheme Hassonic \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build
xcrun simctl install booted /path/to/Hassonic.app
xcrun simctl launch booted com.example.Hassonic.dev   # <BUNDLE_ID_PREFIX>.Hassonic.dev
```

Then in the Simulator app: **I/O → External Displays → CarPlay**. A CarPlay
head-unit window opens next to the phone window; Hassonic appears on its
home screen. Sign in on the phone window first — CarPlay reuses the saved
credentials, but there's no way to log in from the car screen.

There is no `simctl` command for the CarPlay display; it has to be the menu
item.
