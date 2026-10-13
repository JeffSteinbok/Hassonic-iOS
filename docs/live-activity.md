# Speaker Live Activity: how it stays up to date

The speaker Live Activity is a lock screen and Dynamic Island card. It shows
where a media account is playing, with one-tap zone buttons and volume −/+.
This doc covers the one question that drives most of the design: **how does
the card learn about changes, and what does each option cost?**

Tracking: #113 (local), #114 (push updates), #115 (push-to-start).

## The short answer

**A Live Activity does not need any push or notification pipeline.** The app
can start it, update it and end it on its own, and its buttons run inside
the app. That is the [local-only approach](#a-local-only-shipped-in-113) below,
and it works today with no server and no Home Assistant changes.

A push pipeline only adds two things:

1. **Updates while the app isn't running.** For example, someone moves the
   music from an Echo while your phone is in your pocket.
2. **Starting the card without opening the app.** For example, music starts
   from an Echo and the card appears on its own.

Everything else in this doc is about whether those two are worth the cost.

## What iOS allows

- The app can start, update and end its own activities while it's running.
  A start needs the app in the foreground.
- Buttons on the card run an App Intent **in the app's process**. iOS
  launches the app in the background to do it, so a tap always works, and
  the app updates the card right after.
- With the app suspended, the **only** ways to change the card are:
  - an APNs push, or
  - background app refresh. iOS decides when that runs: rarely, and
    unpredictably.
- APNs pushes to this app must be signed with **our** Apple developer key.
  Nobody else's server can push to it: not Home Assistant's, and not another
  household's.
- iOS removes an activity after about 8 hours whatever we do.

## Approaches

### A. Local only (shipped in #113)

The app runs everything. It starts the card when the selected account
starts playing while the app is open, keeps it in step with Home Assistant
while the app runs, and ends it when playback stops. If the card goes 15
minutes with no update, it shows "May be out of date. Open the app to refresh."

| Pros | Cons |
| --- | --- |
| No server, no cost, nothing to deploy | Changes made elsewhere aren't shown until the app next runs |
| No Home Assistant changes | Only starts when the app is opened while music is playing |
| Works for any household, App Store or self-built | |
| Your own taps on the card are always accurate | |

### B. Local plus background refresh

Like A, plus a `BGAppRefreshTask` that reconnects to Home Assistant and
updates the card whenever iOS lets it run.

| Pros | Cons |
| --- | --- |
| Still no server and no Home Assistant changes | iOS decides how often: often hours apart, sometimes never |
| Narrows the stale window a bit, for free | Can't start the card |
| | Spends background budget on a reconnect each time |

### C. Hosted relay, Home Assistant `rest_command` (built in #117/#118)

An Azure Function (`push/`) holds the APNs key. A Home Assistant automation
calls it through a `rest_command` whenever a media account changes. The
relay works out what the card should show and pushes it to Apple. It can
also push-to-start.

| Pros | Cons |
| --- | --- |
| Updates within seconds, with the app closed | **Home Assistant YAML plus a restart** to add `rest_command`; can't be done from the UI |
| Push-to-start works | The relay's key lives in Home Assistant's `secrets.yaml` |
| About $0 on Azure Flex Consumption | A cloud service to keep deployed |
| | Every household has to install the package |

### D. Hosted relay, Home Assistant `mobile_app` notify (proposed)

Same relay as C, but Home Assistant reaches it the way the official
companion app's notifications do. The app registers with Home Assistant's
built-in `mobile_app` integration, with the relay as its `push_url`. Home
Assistant then creates `notify.mobile_app_<device>`. An ordinary UI
automation calls that notify service with the account's state in `data`, and
Home Assistant posts it to the relay.

| Pros | Cons |
| --- | --- |
| Same speed and push-to-start as C | The automation targets one device's notify service; if that device goes away, re-point it |
| **No YAML, no restart**: the registration is automatic and the automation is a normal UI one | A second "Hassonic" device appears under `mobile_app`, next to the companion app's |
| The relay's key is inside the registered `push_url`, not in Home Assistant config | The app's existing registration code has to be un-gated from Firebase |
| The same path would carry ordinary notifications later | Still a cloud service, as in C |

### E. Hosted relay polls Home Assistant

The relay checks each account's state on a timer over Home Assistant's
external URL, so nothing on the Home Assistant side calls out.

| Pros | Cons |
| --- | --- |
| Nothing to install in Home Assistant | Updates lag by the polling interval |
| | Needs Home Assistant reachable from Azure, plus a stored HA token in the cloud |
| | Runs around the clock, even when nothing is playing |

### F. Home Assistant sends to Apple directly

A custom Home Assistant integration (via HACS) holds the APNs key and calls
Apple itself. There's no cloud piece.

| Pros | Cons |
| --- | --- |
| No cloud service at all | Only works for someone signing the app with **their own** developer key (self-built); App Store users can't have our key |
| One hop, fastest possible | A custom integration to maintain across Home Assistant upgrades |

### G. Firebase relay (rejected)

This is the companion-app pattern the repo's `relay/` folder copies:
Home Assistant → Cloud Function → FCM → APNs. It was never configured
(`GoogleService-Info.plist` is still a placeholder). The companion app uses
FCM because it also ships on Android. We're iOS only, so FCM is just an
extra hop that needs the Firebase SDK, a Firebase project and the Blaze
billing plan, and the Live Activity sender would still have to be written.

## Comparison

| | A | B | C | D | E | F |
| --- | --- | --- | --- | --- | --- | --- |
| Accurate while app closed | no | sometimes | yes | yes | lagged | yes |
| Starts without opening the app | no | no | yes | yes | yes | yes |
| Server to run | none | none | Azure | Azure | Azure | none |
| Home Assistant changes | none | none | YAML + restart | UI automation | none | custom integration |
| Works for App Store users | yes | yes | yes | yes | yes | no |

## Recommendation

1. **Ship A now.** Merge #116 once it's checked on a device. It's the whole
   feature for anything done from the card or with the app open, and it has
   no moving parts.
2. **If staleness turns out to matter in practice, go to D, not C.** It
   gives the same result with no YAML or restart, and lays the path for
   real notifications later.
3. B isn't worth building: the timing is too unreliable to change how the
   card feels.

