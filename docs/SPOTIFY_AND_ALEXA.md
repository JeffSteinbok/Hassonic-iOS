# Spotify Multi-Account Switching via Alexa

This document covers how Hassonic moves a physical speaker between different
household members' Spotify accounts, and the (non-obvious) reasons the flow is shaped
the way it is. This mechanism took a lot of live trial-and-error against a real Home
Assistant instance to get right — read this before changing it.

---

## Why this exists

Each Spotify account (Jamie, Morgan) is its own Home Assistant `media_player` entity
(`media_player.spotify_jamie_sterling`, `media_player.spotify_morgan_sterling`). A
physical speaker (e.g. Kitchen) can only be in **one** account's Spotify Connect
`source_list` at a time — it has to be explicitly "claimed" by an account before that
account's entity can `select_source` to it.

Home Assistant / the Spotify integration has no service call to move a speaker between
accounts. The only way to do it is to simulate the same voice command a person would
say to an Echo: *"Switch to Morgan's account"*, then *"Play Spotify on Kitchen"*. This
is done by calling `media_player.play_media` with `media_content_type: "custom"` on an
Alexa `media_player` entity — the app is essentially typing words for Alexa to "hear."

---

## Entities involved

| Entity | What it is |
|---|---|
| `media_player.spotify_<person>_sterling` | The Spotify integration entity for that account. Has `source`/`source_list` (available Connect devices) and is what `select_source`/`play_media` target for actual playback control. |
| `media_player.<room>` | The Alexa entity for the **default/primary** household member on that Echo. |
| `media_player.<room>_<person>` | The Alexa entity for a **secondary** profile on the same physical Echo (e.g. `media_player.main_bedroom_morgan`). Same hardware, different voice profile. |

`speakerClaim.deviceEntityIds` in `hassonic.yaml` is a single list — the
Alexa devices used to voice-command *any* account's switches, in priority order. This is
**shared across all accounts, not per-account**: which entity issues the voice command
doesn't matter, since it's just relaying a household profile switch — any working device
can ask to switch to any account (confirmed live: `media_player.family_room` alone
successfully switched to both Jamie and Morgan). It's a curated list of devices
**confirmed to actually respond** to custom voice commands, not just any device in the
household (see [Known device quirks](#known-device-quirks-important)).

---

## The flow

```mermaid
flowchart TD
    Start([User picks a zone to play on]) --> Try[1. Try select_source directly<br/>~5s timeout]
    Try -->|confirmed / already active| Success([Done — dismiss])
    Try -->|timeout| Detect[2. Infer: zone not on this account<br/>select_source gives no error even<br/>when it's a no-op, so timeout is<br/>the only signal]

    Detect --> Device[3. Try next device in alexaSwitchingDeviceIds]
    Device --> Switch[Send 'Switch to {account}'s account'<br/>poll last_called_response, ~16s]
    Switch -->|confirmed right account| Cooldown[Wait 1.5s cooldown]
    Switch -->|wrong account or no response| Attempt2{First attempt<br/>on this device?}
    Attempt2 -->|yes| Switch
    Attempt2 -->|no, already retried| NextDevice{Another device<br/>in the list?}
    NextDevice -->|yes| Device
    NextDevice -->|no| HardFail([Fail: report which<br/>devices were tried])

    Cooldown --> Play[Send 'Play {content or U2} on Spotify on {speaker}'<br/>wait ~3s — see History #11]
    Play --> Retry[4. Retry select_source<br/>~15s timeout — longer than step 1's,<br/>see History #8]
    Retry -->|confirmed| Success
    Retry -->|timeout| SoftFail([Fail: moved account but<br/>couldn't confirm])
```

**Why one retry per device, for any failure type:** both "wrong account" (Alexa
misheard) and "no response" (backend hiccup) can be transient — worth one retry before
concluding the device itself is the problem and moving to the next one.

**Why the 1.5s cooldown before the play command:** sending two custom commands back-to-back
to the same device can make Alexa's backend silently drop the second one (no
`last_called_*` update at all, even though the first command clearly worked). A short
gap avoids this.

**Why the play phrase includes real content** (`"Play U2 on Spotify on {speaker}"`, not
just `"Play Spotify on {speaker}"`): confirmed via a direct live A/B test — with the
plain phrase, the account switch itself would succeed (audible confirmation, correct
`last_called_response`) but nothing ever actually started playing on the target zone,
and it never appeared in the account's `source_list` even a minute later. Swapping back
to real content (`"Play U2 on Spotify on {speaker}"`) on the identical setup immediately
produced audible playback on the target zone. The plain phrase apparently isn't enough
to force Alexa into an actual Spotify Connect handoff — it needs a real, playable item.
When the app knows what was actually requested (e.g. a favorite tap), it asks for that
by name directly instead of "U2" — no reason to force a throwaway placeholder when the
real thing works exactly as well (see History #11). "U2" remains the fallback for
switches with no specific content in mind. Either way, the app still follows up with a
normal `play_media` call once this whole flow returns, both as the only mechanism for
content-less switches and as a precision correction otherwise.

---

## Detecting success/failure — there's no error signal

`media_player.select_source` and the custom Alexa `play_media` calls both return
**HTTP 200 with no error even when they're a complete no-op**. The only way to know
whether something actually happened is to watch for the resulting state change:

- `select_source`: poll the Spotify entity's `source` attribute for the requested value.
- Alexa switch: poll the Alexa entity's `last_called_response` attribute — but only trust
  a response whose `last_called_timestamp` is *strictly after the moment this specific
  command was sent* (with a couple seconds' tolerance for clock skew), not just "recent."
  **This bit us in practice**: an earlier version checked "is `last_called_timestamp`
  within the last 12 seconds", which isn't the same thing — a stale response from an
  unrelated command sent moments earlier could still fall inside that window and get
  misread as the answer to the *current* command (e.g. correctly hearing "Now in
  Morgan's account" out loud, while the code read an older "Now in Jamie's account" left
  over from the previous interaction and reported the wrong result). Always compare
  against this specific command's send time, never a fixed recency window.

`source_list` on the Spotify entity (which zones are currently reachable) is **not**
a reliable real-time signal — see below.

---

## Known device quirks (important)

- **Not every Alexa-connected speaker responds to custom voice commands.** Some take
  standard playback controls (volume, play/pause) fine but never produce any
  `last_called_*` update for a `custom` `play_media` call — confirmed for
  `media_player.home_theater` and `media_player.hallway` in this household (volume
  control on Home Theater worked instantly; the custom command produced zero change
  over 8+ seconds, repeatedly). This is why `alexaSwitchingDeviceIds` is a curated
  allowlist, not any Alexa device in the household.
- **This might partly be rate-limiting, not a hard device limitation** — after heavy
  test traffic in one session, even previously-reliable devices (Main Bedroom) stopped
  responding to anything for a while. This was never fully disentangled from "device
  doesn't support it." If a device on the list starts failing consistently, don't
  assume it's permanently bad — retest after a cooldown period before removing it.
- **Entity naming**: the default/primary household member's Alexa entity has no
  suffix (`media_player.main_bedroom`); other profiles get `_<name>` appended
  (`media_player.main_bedroom_morgan`). This isn't documented anywhere in HA — it was
  reverse-engineered by listing all `media_player.*` entities and pattern-matching.
- **`source_list` on the Spotify entity lags real state by up to ~90 seconds.** Do not
  pre-check it to decide whether a zone is bound before attempting the switch — always
  just try `select_source` first and infer from the timeout (step 1–2 above).

---

## History — things we learned the hard way

Roughly in the order discovered, since some of this took real effort to pin down:

1. Two Spotify accounts can both list the *same* physical Echo as an available Connect
   device — it's not always a clean single-owner handoff. A device that's actively
   playing under one account can get silently reclaimed by that account's other client
   (e.g. someone's phone app) shortly after a switch, if that session was never
   properly told to release the device.
2. The HA rebinding script originally used had a broken `alexa` entity map (pointed
   `media_player.main_bedroom_jamie`, which didn't exist, instead of
   `media_player.main_bedroom`) — always verify entity IDs actually exist via
   `/api/states/<id>` rather than trusting a script's config.
3. Moved off calling a shared HA script entirely and onto sending the two
   `media_player.play_media` custom commands directly from the app — this puts timing
   fully under the app's control (poll-then-proceed instead of a fixed delay), which
   is what enabled steps 3–4 of the flow above.
4. `scripts/ha_music_flow.py` (repo root) exercises this exact flow directly against a
   live HA instance, reading the real config from `hassonic.yaml`, for fast iteration
   without going through the simulator or a physical device. Needs `HA_URL`/`HA_TOKEN`
   in the environment or a gitignored `.ha.env` file at the repo root.
5. Alexa devices were originally configured per-account (a device list per `SpotifyAccount`).
   Switched to one shared `alexaSwitchingDeviceIds` list for all accounts once it became
   clear the command device doesn't need to have anything to do with the target account —
   it's just relaying a spoken command.
6. Found and fixed a real bug in the response-freshness check: it accepted any
   `last_called_response` within a fixed recency window (12s) instead of requiring it be
   newer than when the current command was actually sent. This let a stale response from
   an unrelated prior command get misread as confirming (or denying) the current one —
   see [Detecting success/failure](#detecting-successfailure--theres-no-error-signal) above.
7. The account-switch poll window was 8s, but a genuine round trip (voice command ->
   Alexa backend -> spoken response -> HACS attribute update) can take longer — one
   clean, isolated live measurement came back at 11.2s. With an 8s window, attempt 1
   would reliably time out as "no response" even though Alexa was correctly mid-flight,
   and the retry logic would fire a second, audible "Switch to {account}'s account"
   command before the first one's real answer had even landed. Widened the window to
   16s. If this still proves too tight under real-world load, look at actual observed
   latency again before just bumping the number further.
8. `selectSourceConfirmed` had a single hardcoded 5s timeout used for *both* step 1
   (the initial "is this zone already on this account" probe, where 5s is correct — a
   same-account switch confirms in ~2-3s) and step 4 (confirming a handoff Alexa just
   forced live). Those aren't the same kind of wait: a fresh cross-account handoff
   measurably takes longer for HA's polled `source` attribute to catch up (10s+
   observed live). With the short timeout, step 4 would give up before `source`
   caught up, PlayOnSheet reported failure, and — since the real requested content is
   only sent on success — playback was left stranded on the forcing "Play U2..." track
   instead of what was actually asked for. Added a `timeout:` parameter to
   `selectSourceConfirmed` so step 4 can use its own longer window (15s) independently
   of step 1's.
9. Even 15s wasn't always enough — confirmed live, source had already flipped to the
   correct zone with the actually-requested content playing shortly after the app gave
   up and reported failure. Step 4's timeout is no longer treated as a hard failure:
   since Alexa already confirmed the switch and forced a real, audible handoff, that's
   solid enough evidence to proceed and send the real requested content regardless of
   whether HA's polled `source` attribute has caught up yet. The 15s wait is now purely
   about how long the progress UI waits before moving on, not a pass/fail gate.
10. Proceeding early (#9) surfaced the next layer of the same problem: the real
    requested content's `play_media` call, fired right at that soft-success moment, can
    itself land *during* the still-in-progress handoff and get silently dropped (200
    response, no effect) — confirmed live, content stayed on the forcing "Play U2..."
    track. A `play_media` call sent minutes later, once things had genuinely settled,
    worked instantly — so the mechanism itself is fine, it's purely a timing race.
    `FavoritesBar` now resends the same `play_media` call several more times (at +5s,
    +12s, +25s, +45s, +70s) whenever the pick required an actual account switch —
    harmless if an earlier call already worked (just restarts the same content), but
    catches the drop otherwise. Skipped entirely when the zone was already on the
    right account, since there's no drop risk there and resending would just
    needlessly restart correct playback.
    An initial narrower window (+4s/+10s) wasn't enough — live testing showed content
    could still be stuck on the forcing track 45-50s after the Alexa switch confirmed,
    matching the `source`/`source_list` lag already documented elsewhere as up to ~90s
    worst case. Widened the schedule accordingly rather than guessing at one more fixed
    delay.
11. Even the widened schedule didn't reliably close it — live testing still found Kitchen
    stuck on the forcing content well past 70s in one run. Rather than keep chasing the
    settling window, addressed the actual root cause: the forcing phrase itself no
    longer needs to be a placeholder. When the pick came from a favorite, the forcing
    phrase now asks Alexa for that content **by name** directly (e.g. "Play Taylor
    Swift on Spotify on Kitchen") instead of "Play U2 on Spotify on {speaker}" — this
    is exactly as reliable as the U2 placeholder (same mechanism, same live A/B-tested
    behavior of forcing a genuine Connect handoff), so there's no longer a gap where
    the zone is stuck on unrelated content while a separate, timing-fragile
    `play_media` API call tries to land. That follow-up API call (see #10) still runs
    afterward as a precision correction (in case Alexa's own interpretation of the name
    differs, or picks a different track within the artist), but it's no longer the sole
    path to correct content — Alexa's own request already gets the right thing playing
    immediately. `HAWebSocketClient.switchSpeakerToAccount` gained a `contentName:`
    parameter for this; `PendingPlayAction.playMedia` and `PlayOnSheet` thread the
    favorite's `displayName` through to it. Switches with no specific content in mind
    (e.g. NowPlayingCard's play/pause-triggered switch) still fall back to "U2".

## Configuration

Everything about the claim step is declared under `speakerClaim` in
`hassonic.yaml` (see [Configuration](configuration.md)). Omit it and the
step is unavailable: `PlayOnSheet` says so plainly instead of failing at
something that was never set up. Nothing about it is hardcoded to Alexa; any
device that takes a spoken command through `media_player.play_media` and
reports its reply in attributes could be described the same way.

```yaml
speakerClaim:
  deviceEntityIds: [media_player.kitchen_echo]
  command:      { contentType: custom, phrase: "Switch to {account}'s account" }
  confirmation: { timestampAttribute: last_called_timestamp,
                  responseAttribute:  last_called_response,
                  matches: "in {account}'s account" }
  playback:     { phrase: "Play {content} on Spotify on {speaker}",
                  fallbackContent: "U2" }
  timings:      { replyTimeoutSeconds: 16, pollIntervalMs: 500,
                  commandCooldownMs: 1500, settleSeconds: 3,
                  attemptsPerDevice: 2 }      # optional
```

Only `timings` has defaults (they were measured, not chosen). Every other field
is required whenever the block is present, and a partial block is rejected by
name. `{account}`, `{speaker}` and `{content}` are substituted at call time.

Two reasons this is data rather than code:

- **`confirmation.matches` is a substring test against a spoken English
  reply.** If Amazon rewords it, the feature breaks with no change on our
  side, and it fails *audibly* — retrying out loud in the kitchen. As config
  that is an edit, not a release.
- The timings were derived from live measurement, not chosen. They can be
  retuned without a rebuild when the vendor's latency changes.

It also means a non-English household can use the feature at all.
