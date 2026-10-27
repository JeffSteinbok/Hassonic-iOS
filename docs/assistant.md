# Assistant

This is the device-to-OpenClaw integration guide. See
[Jev safety skill / Hass Guard](assistant-safety.md) for server-side home-control
policy, protected credentials, the decision threshold and troubleshooting.

Hassonic sends directives only to the `hassonic` agent on your OpenClaw gateway. Enable Assistant in
your Home Assistant-hosted YAML:

```yaml
assistant:
  title: Assistant
  system_icon: sparkles
  session: main
```

The agent is fixed to `hassonic` in app code. Legacy `assistant.agent` values
are ignored, including in cached configurations. `session` can select another
conversation within that agent and accepts 1–64 lowercase letters, digits,
underscores and hyphens, starting with a letter or digit.
Without this block there is no Assistant microphone, no gateway
connection and no Assistant Keychain access. `assistant` becomes a reserved
page ID while Assistant is enabled.

The assistant's displayed name is fetched after authentication using
`agent.identity.get` with the pinned `hassonic` agent and its session key.
It is not carried by the pairing code and is not hardcoded to any owner's
name. For example, a gateway identity named Octo displays Octo in the directive
sheet, gateway settings, progress, errors and microphone accessibility label.
The display falls back to OpenClaw before the lookup or if the gateway denies
or does not support it. This optional lookup never blocks commands or requests
additional scopes. The legacy YAML `title` field remains accepted but does not
override the gateway-provided assistant name. Names are refreshed on reconnect
and cleared when forgetting or replacing a gateway.

The gateway must actually have an agent named `hassonic`; pinning its name in
the app does not create it. Give it its own workspace and an appropriate tool
policy. An absent agent is shown as "Not sent", not a connection interruption.

A microphone beside the hamburger menu opens Assistant from Music, dashboard
pages and rooms. It presents a directive sheet without changing the current
page or adding a tab. `hassonic://assistant` opens the same sheet.
The toolbar microphone starts listening; a notification/deep link only opens
status and never starts recording by itself.

## Pair a device

The gateway must support protocol v4 and limited mobile pairing. Tested
against OpenClaw 2026.10.2 and 2026.10.4. Use a `wss://` endpoint with a certificate trusted
by iOS, such as your existing HTTPS reverse proxy. Plain `ws://`, embedded
credentials and query-string credentials are rejected; there is no TLS bypass.

On the gateway host:

```sh
openclaw qr --limited --setup-code-only --url wss://your-gateway.example
```

Open Settings, then the assistant's Gateway entry. Scan a limited pairing QR
code (generated without `--setup-code-only`) or paste that setup code. Check the
displayed gateway address, then tap Connect gateway. Scanning never pairs or
sends a directive automatically. Camera permission is requested only when you
tap Scan QR code; paste remains available if camera access is denied or scanning
is unsupported. The microphone's unpaired screen also links to Gateway
Settings. Treat the code as a
secret. Depending on the gateway's mobile pairing policy, the code itself
authorizes pairing or the owner must approve the pending request:

```sh
openclaw devices list
openclaw devices approve <request-id>
```

The code is short-lived and kept only in memory. Hassonic persists an
Ed25519 device key and the issued operator credential in its own Keychain
service, with `AfterFirstUnlockThisDeviceOnly` accessibility and no iCloud
sync. Debug and Release have separate identities. It does not store your
shared gateway token or the temporary node credential.

### Change the gateway address

For the same trusted gateway at a new hostname, open Settings → the assistant's
Gateway entry, edit the address under "Gateway moved?", and tap "Save address &
reconnect". Bare hostnames, HTTPS and WSS addresses are accepted and normalized
to WSS. Confirm the exact destination: the existing device credential will be
sent there. Your device identity and pairing are preserved; no directive is sent.

For a different gateway, use "Pair a different gateway" and a fresh limited setup
code instead. The saved pairing is replaced only after the new bootstrap succeeds.
"Forget gateway" removes the local pairing and immediately shows the setup-code
form on the same screen; it does not revoke the device on the server. These
changes are disabled while a directive is running. Gateway setup never opens
the microphone or automatically sends a command.

OpenClaw's mobile setup protocol initially connects as a node with no
capabilities, commands or requested scopes, then hands over an operator
credential. Hassonic closes that connection and reconnects as an operator
requesting `operator.read`, `operator.write` and `operator.approvals`. The
approval scope is needed by the admitted run to request and wait for plugin
approvals, even when the gateway delivers review to Discord. Hassonic does not
automatically approve requests or add administrator/pairing access. It rejects
administrator or pairing credentials. The limited bootstrap credential may still carry
additional OpenClaw scopes such as Questions and Talk secrets; requesting
fewer scopes on a connection does not remove authority from the credential.
The approvals scope also permits approval management if the credential is
used outside this app; this remains a trusted-household-device boundary.

## Permission boundary

The pinned agent and configured session are application routing choices, not a server
authorization boundary. A device credential with broad operator read/write
authority may access other agents or gateway operations if used outside
Hassonic. This implementation is for trusted household devices on one trusted
gateway. Do not treat it as isolation between mutually untrusted users.

Agent tools and sandbox policy are enforced on the gateway. Review those
policies separately; Hassonic does not change them or grant additional tools.
The reference household's `hass-guard` plugin checks HA service calls with Jev;
its current policy blocks low-confidence/unavailable evaluations rather than
automatically requesting approval. It is configured separately from this app.
Gateways using verified-person roles may reject device-token authentication;
identity-proxy authentication is not implemented in this client.

## Record, send and track a directive

- Tap the toolbar microphone and speak. Recording starts when connected; the
  panel shows Listening and the live transcription. A short pause finishes
  speech recognition and sends the directive automatically. There is no review
  screen, Send button, or conversation history. Cancel closes the microphone
  without sending; Finish speaking ends recognition immediately.
- The same compact panel changes to Sending, Working and the final result.
  Clear failures say what needs fixing. A lost acknowledgement is reported as
  uncertain, never automatically retried. Silence sends nothing.
- Stop requests cancellation of the current run. It cannot undo an action
  that already happened.
- Closing the sheet keeps its connection alive while the app is in the
  foreground. Tap the toolbar microphone to return to a running directive.
- Backgrounding closes the socket and marks an unfinished directive's status
  unavailable. It may still be running on OpenClaw. No directive is automatically
  resent, and a missed final response is not reconstructed from shared history.
- Assistant connection details and Forget gateway are available in Settings.
  Forget deletes local credentials
  and the device key; it does not revoke the server's device record.
- Revoke a lost device on the gateway, using the device ID shown in Settings:

  ```sh
  openclaw devices revoke --device <device-id> --role operator
  ```

Chat frames, setup codes and credentials are not logged. Tool results and
hidden reasoning are not rendered. Only the current device's directive and
result are held in memory; shared conversation history is not fetched.

## Notifications

Sending commands and receiving replies while Assistant is open needs no push
service. For notifications while the app is closed, use your Home Assistant
mobile-app notify service and the existing push relay:

```yaml
action: notify.mobile_app_your_phone
data:
  title: Assistant
  message: Your task has finished.
  data:
    url: hassonic://assistant
```

Tapping a notification opens its `data.url` if it uses the `hassonic` scheme.
The app queues the link through startup and configuration loading. Missing,
invalid or foreign-scheme URLs are ignored. Notifications show banners in
the foreground. OpenClaw's restricted Home Assistant notification tool is a
separate gateway/plugin feature; this app does not install it.

## Protocol references

For an opt-in physical-device integration test, copy a fresh limited setup code
to the Dev app's `Documents/openclaw-assistant-setup-code.txt`, then run
`AssistantDeviceIntegrationTests/testLiveDevicePairingAndChat` on that device.
To test an already-paired phone without replacing its credential, supply an
empty `Documents/openclaw-assistant-live-test.txt` marker instead. The test
consumes either opt-in file before using the live gateway.
The test consumes the setup file, uses the `hassonic` agent and configured session,
sends a harmless connectivity request and leaves the issued credential in
Keychain for normal use. Without either opt-in file it skips and makes no connection.

- [OpenClaw gateway protocol](https://docs.openclaw.ai/gateway/protocol)
- [Device authentication](https://docs.openclaw.ai/gateway/protocol/auth)
- [Operator scopes](https://docs.openclaw.ai/gateway/operator-scopes)

The signing implementation follows the OpenClaw v2 compatibility payload
contract in `DeviceAuthPayload.swift`. OpenClaw is MIT licensed; see
[the upstream license](https://github.com/openclaw/openclaw/blob/main/LICENSE).
