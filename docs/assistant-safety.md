# Jev safety skill / Hass Guard

The household's "Jev safety skill" is implemented by the separate OpenClaw
`hass-guard` plugin, not an iOS permission check or a chat prompt. This document
describes the deployed **hass-guard 0.1.2** policy checked on 2026-10-17. The app
does not install that plugin; other gateways must supply their own tool policy.
See [Assistant integration](assistant.md) for device pairing and transport.

## Execution boundary

```text
Hassonic directive → hassonic agent → proposed Home Assistant tool call
  → agent tool permissions → hass-guard service/target allowlist
  → Jev Boolean evaluation → execute only if probabilityTrue ≥ 0.85
                           → otherwise block and explain
```

The hook applies only to configured agent IDs (default: `hassonic`). Read-only
`hass_state_get` and `hass_state_list` pass through. `hass_service_call` must pass
both deterministic validation and Jev. Other `hass_*` tools are blocked for
guarded agents; unrelated tool names remain subject to OpenClaw's tool policy.
Keep that policy narrow: the reference agent allows HA state/service tools and
web search/fetch, not files, shell execution, messaging, or automation editing.

The service allowlist covers selected light/switch/fan, media-player/remote,
Xfinity, scene, climate, cover and input-helper operations. It is not permission
to call every service in those domains. Scripts are restricted to explicit names.
Targets must be explicit entity IDs in the expected domain; an absent target,
`all`, or target-widening keys inside `data` are rejected. The plugin source's
`ALLOWED_SERVICES` and `ALLOWED_SCRIPTS` are authoritative.

Jev receives the proposed action, entity IDs, service data and local time—not
the entire conversation. Its rubric asks whether the action is routine and safe
to perform without asking the homeowner. Routine comfort/entertainment actions
are positive examples; purchases, security/privacy changes, unusual values and
potentially harmful actions are negative examples.

`probabilityTrue` is model confidence in that rubric, **not a measured percentage
of physical safety**. The hard allowlist still applies even with a high score.
Below 0.85, a malformed answer, timeout, missing credential or unavailable model
blocks the call. The agent must report that the action was not performed.

## Gateway setup

Install compatible Home Assistant, TypeSafe and Hass Guard plugins separately.
The TypeSafe decision API requires OpenClaw/plugin API 2026.9.6 or later; the
integration was exercised with OpenClaw 2026.10.4. Merge settings into the
existing configuration; do not replace unrelated agents or plugin entries:

```json
{
  "agents": {
    "entries": {
      "hassonic": {
        "decisionModel": "typesafe/jev-latest",
        "tools": {
          "allow": [
            "hass_state_get", "hass_state_list", "hass_service_call",
            "web_search", "web_fetch"
          ]
        }
      }
    }
  },
  "plugins": {
    "entries": {
      "typesafe": {
        "enabled": true,
        "config": {
          "apiKey": {
            "source": "store", "provider": "default", "id": "TYPESAFE_API_KEY"
          }
        }
      },
      "hass-guard": { "enabled": true, "config": { "agents": ["hassonic"] } }
    }
  }
}
```

This is a fragment, not a complete gateway configuration. The `hassonic` agent
still needs its workspace/identity and the Home Assistant plugin its own protected
server credential. The TypeSafe API key and the HA token are different secrets.

Create `TYPESAFE_API_KEY` as a protected secret in OpenClaw Settings → Secrets,
or import it through stdin using `openclaw secrets store set TYPESAFE_API_KEY
--kind secret --allow-host api.typesafe.ai --value-file -`. Never pass the key
as a command-line literal, commit it, or paste it into a directive. Hosted Jev
calls send the selected evidence to TypeSafe and incur normal usage charges.
Enabling the plugin alone does not select a model or configure a credential.

Apply configuration through supported hot reload and `openclaw secrets reload
--json`; verify success rather than assuming a file edit is active. Plugin
replacement may wait for existing work. A queued/failed reload is not successful
activation. Do not restart the gateway to force it without the operator's approval.

## Approvals versus safety rejection

The older guard version used human approval as its low-confidence/unavailable
fallback. **Version 0.1.2 blocks instead**; an approval does not override that
guard refusal. Do not tell the user an approval has been requested when it has not.

Other OpenClaw plugins can still require human approval. Hassonic requests
`operator.approvals` alongside read/write because the admitting connection's
authority is propagated into the run and approval request/wait methods need that
scope. Review delivery is configured on the gateway (for example, Discord).
The app does not silently approve requests. This scope is approval-management
authority, not merely a notification subscription; see the integration's
[trusted-device boundary](assistant.md#permission-boundary).

## Verification and troubleshooting

1. Verify the agent exists, the guard is enabled for that ID, and its effective
   `decisionModel` is selected. `openclaw plugins info hass-guard --json` identifies
   the installed version/source; do not assume a source checkout is the deployed build.
2. Verify secret-reference activation without printing the credential. A successful
   `openclaw secrets reload --json` should have `ok: true`.
3. Test rubric calibration with classification-only, realistic examples: TV power,
   channel selection and ordinary lighting versus purchases or extreme settings.
   Do not execute real service calls just to measure a score. A nonexistent entity
   is useful for transport testing, not a benchmark for a real TV command.
4. Test the phone's command/result round trip separately using the opt-in
   [device integration test](assistant.md#protocol-references). It does not prove
   HA control or classifier calibration by itself.
5. Test approval delivery/resolution only when a plugin actually requests review;
   use a clearly labelled diagnostic and never automatically approve real actions.

| Symptom | Check |
|---|---|
| Agent missing / Not sent | The gateway must have `agents.entries.hassonic`; the app cannot create it. |
| HA control tool unavailable | Agent tool policy and Home Assistant plugin installation/configuration. |
| Safety check disabled/unavailable | Effective decision model, TypeSafe credential, reload completion and provider availability. |
| Unexpected low score | Exact rubric/evidence and realistic calibration; do not simply lower the threshold. |
| Approval gateway unavailable | Logs may reveal a missing `operator.approvals` scope, rather than an offline gateway. |
| Plugin replacement / offline maintenance | Wait for completion; do not bypass the guard or repeatedly restart the gateway. |

The pinned agent name is routing, not server-side agent isolation. Removing the
guard while retaining a general HA service-call tool broadens control authority.
Never treat prompt instructions alone as enforcement.
