# Assistant

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

A microphone beside the hamburger menu opens Assistant from Music, dashboard
pages and rooms. It presents a directive sheet without changing the current
page or adding a tab. `hassonic://assistant` opens the same sheet.

## Pair a device

The gateway must support protocol v4 and limited mobile pairing. Tested
against OpenClaw 2026.10.2. Use a `wss://` endpoint with a certificate trusted
by iOS, such as your existing HTTPS reverse proxy. Plain `ws://`, embedded
credentials and query-string credentials are rejected; there is no TLS bypass.

On the gateway host:

```sh
openclaw qr --limited --setup-code-only --url wss://your-gateway.example
```

Tap the microphone, paste that setup code, and tap Connect. Treat the code as a
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

OpenClaw's mobile setup protocol initially connects as a node with no
capabilities, commands or requested scopes, then hands over an operator
credential. Hassonic closes that connection and reconnects as an operator
requesting only `operator.read` and `operator.write`. It rejects administrator
or pairing credentials. The limited bootstrap credential may still carry
additional OpenClaw scopes such as approvals and Talk secrets; requesting
fewer scopes on a connection does not remove authority from the credential.

## Permission boundary

The pinned agent and configured session are application routing choices, not a server
authorization boundary. A device credential with broad operator read/write
authority may access other agents or gateway operations if used outside
Hassonic. This implementation is for trusted household devices on one trusted
gateway. Do not treat it as isolation between mutually untrusted users.

Agent tools and sandbox policy are enforced on the gateway. Review those
policies separately; Hassonic does not change them or grant additional tools.
Gateways using verified-person roles may reject device-token authentication;
identity-proxy authentication is not implemented in this client.

## Record, send and track a directive

- Hold the large microphone to record. Pauses do not end the recording;
  release it to finish, with a one-minute recording limit.
- Review and optionally edit the transcription, then tap Send directive.
  Recording never sends automatically. You can also type a directive.
- The sheet shows live progress and the final result for that directive.
  New directive clears the result. There is no conversation history or chat UI.
- With VoiceOver, double tap the microphone to start and stop recording.
- Stop directive requests cancellation of the current run. It cannot undo an action
  that already happened.
- Closing the sheet while a directive is running keeps its connection alive
  while the app is in the foreground. Tap the toolbar microphone to return.
- Backgrounding closes the socket and marks an unfinished directive's status
  unavailable. It may still be running on OpenClaw. No directive is automatically
  resent, and a missed final response is not reconstructed from shared history.
- Assistant connection details and Forget gateway are available from the
  sheet's information button and Settings. Forget deletes local credentials
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
The test consumes the setup file, uses the `hassonic` agent and configured session,
sends a harmless connectivity request and leaves the issued credential in
Keychain for normal use. Without that file it skips and makes no connection.

- [OpenClaw gateway protocol](https://docs.openclaw.ai/gateway/protocol)
- [Device authentication](https://docs.openclaw.ai/gateway/protocol/auth)
- [Operator scopes](https://docs.openclaw.ai/gateway/operator-scopes)

The signing implementation follows the OpenClaw v2 compatibility payload
contract in `DeviceAuthPayload.swift`. OpenClaw is MIT licensed; see
[the upstream license](https://github.com/openclaw/openclaw/blob/main/LICENSE).
