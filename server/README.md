# Tesstats Push Microservice (optional)

Bridges TeslaMate **MQTT → APNs** so you get alerts **even when the Tesstats app
is closed**, and keeps charging Live Activities current while iOS suspends the
app. It handles charging, security, geofence and software-update transitions.

> **This project is an unofficial community tool and is not affiliated with, endorsed by, or supported by the official TeslaMate project.**
>
> This service is part of Tesstats, an independent app that is not
> affiliated with, endorsed by, or related in any way to the TeslaMate project or
> Tesla, Inc. It only subscribes to the MQTT topics your own TeslaMate already
> publishes. Report problems in the [Tesstats issue tracker](https://github.com/jorgepb96/tesstats/issues),
> not to TeslaMate.

> **Why this is optional.** iOS cannot reliably poll in the background, so the app
> alone can only raise local notifications while it is running. For guaranteed,
> instant alerts with the app closed you need a tiny always-on server that listens
> to MQTT and pushes them out. That's this service. If you don't run it, the app
> still works — it just uses local notifications with that limitation.

It can deliver through **three channels** (any combination):

| Channel | Works with AltStore/sideloaded installs? | Needs Apple Developer account? |
|---|---|---|
| **ntfy** (recommended) | ✅ yes | no |
| **Webhook** (Home Assistant, Node-RED, …) | ✅ yes (notifies via your automation) | no |
| **APNs** (native push to the app) | ❌ **no** | yes (paid) |

> ⚠️ **The APNs caveat, honestly:** sideloaded apps (AltStore/SideStore with a free
> Apple ID) are signed **without the push-notifications entitlement**, so APNs can
> never reach them — no matter how you configure this service. If you install
> Tesstats via AltStore, use **ntfy** or a **webhook** instead; they are just as
> instant and need no Apple account.

## Option A — ntfy (recommended, 2 minutes)

1. Install the **ntfy** app from the App Store and subscribe to a topic with a
   long, secret name (the topic name acts as the password), e.g.
   `tesstats-a8f3k2j9x`.
2. Set `NTFY_URL=https://ntfy.sh` (or your self-hosted ntfy) and
   `NTFY_TOPIC=tesstats-a8f3k2j9x` on this service.
3. Done — Sentry alerts arrive as *urgent-priority* ntfy pushes with the app closed.

## Option B — Webhook → Home Assistant automations

Set `WEBHOOK_URL` (e.g. an HA webhook trigger). Each event POSTs:

```json
{ "title": "Possible Sentry event", "body": "…", "carId": "1", "event": "sentry", "ts": "2026-07-10T18:00:00Z" }
```

From there, automate anything: phone notification via the HA companion app,
turn on the lights, sound a siren, send a Telegram message…

## Option C — APNs (only for Xcode/TestFlight installs)

1. An **Apple Developer account** (for the APNs Auth Key) and the app installed via
   Xcode/TestFlight with the **Push Notifications** capability enabled.
2. An **APNs Auth Key** (`.p8`): Apple Developer → *Certificates, Identifiers & Profiles*
   → *Keys* → **+** → enable **Apple Push Notifications service (APNs)** → download the
   `AuthKey_XXXXXXXXXX.p8`. Note the **Key ID** and your **Team ID**.

## Run with Docker (alongside TeslaMate)

Add to your existing `docker-compose.yml` (same network as `mosquitto`):

```yaml
  tesstats-push:
    build: ./tesstats-push        # or image: yourrepo/tesstats-push
    restart: always
    environment:
      - MQTT_URL=mqtt://mosquitto:1883
      - MQTT_USERNAME=tesstats
      - MQTT_PASSWORD=<your-mqtt-pass>
      - TOPIC_ROOT=teslamate/cars
      - PORT=8090
      - REGISTER_TOKEN=<long-random-secret>
      - APNS_KEY_PATH=/keys/AuthKey_ABCDE12345.p8
      - APNS_KEY_ID=ABCDE12345
      - APNS_TEAM_ID=YOURTEAMID
      - APNS_BUNDLE_ID=com.tesstats.app
      # TestFlight and App Store tokens require the production APNs endpoint.
      - APNS_PRODUCTION=true
      - LIVE_ACTIVITY_TOKENS_FILE=/app/data/live-activity-tokens.json
      - DEVICE_PREFERENCES_FILE=/app/data/device-preferences.json
    volumes:
      - ./tesstats-push/keys:/keys:ro
      - ./tesstats-push/data:/app/data
    depends_on:
      - mosquitto
```

Expose `tesstats-push:8090` through your reverse proxy (e.g. `push.example.com`)
**with Basic Auth / TLS** so the app can register its device token.

## How the app uses it

1. In **Tesstats → Settings → Alerts**, enable **Immediate push** and set the
   **Push service URL** (e.g. `https://push.example.com`) and the **shared secret**
   (`REGISTER_TOKEN`).
2. The app asks iOS for a device token and `POST`s it to `…/register`:
   ```json
   {
     "token": "<apns-device-token>",
     "secret": "<REGISTER_TOKEN>",
     "preferences": { "chargingComplete": true, "updateAvailable": true }
   }
   ```
3. This service watches MQTT and pushes to every registered token when an event fires.
   Dead tokens (HTTP 410 / BadDeviceToken) are pruned automatically.
4. When charging begins, ActivityKit gives the app a short-lived Live Activity token.
   The app registers it at `/register-live-activity`; the service then sends battery,
   power, range and ETA updates directly to the Lock Screen while Tesstats is suspended.

For a TestFlight install, `APNS_PRODUCTION` **must** be `true`. Sandbox is only
for an app launched from Xcode with a development provisioning profile. After
changing environments, open Tesstats once so the current device token is
registered again, then use **Send remote test** in Settings → Alerts.

## Endpoints

- `POST /register` — stores the device token and its optional alert preferences.
- `POST /register-live-activity` — stores one ActivityKit token plus car, language,
  units, range preference and accent metadata.
- `POST /test` — `{ secret, title, message }` → sends a diagnostic push to registered devices.
- `GET  /healthz`  — `{ ok, tokens, apnsConfigured, apnsEnvironment }`.

## Events

| Event | Trigger | Env toggle |
|---|---|---|
| Possible Sentry | `center_display_state` becomes `7` (one alert per `SENTRY_COOLDOWN_SEC`, default 10 min) | `NOTIFY_SENTRY` |
| Unlocked while parked | `locked` true→false while not driving | `NOTIFY_UNLOCKED` |
| Something open | door/frunk/trunk/window opens while parked | `NOTIFY_OPENINGS` |
| Charging started / complete / target | charging and battery transitions | app preference |
| Left unplugged / plugged idle | parking and charging transitions | app preference |
| Software update | `update_available` becomes true | app preference |
| Geofence | geofence changes | app preference |

The app sends its alert preferences with each APNs device-token registration, so
disabled categories are filtered per iPhone. Deploy the server included with the
same Tesstats release as the app; older server builds do not expose the Live
Activity registration endpoint.

## Honesty

- The Sentry alert is an **inference** from the car's screen state. TeslaMate does
  not expose a dedicated Sentry event, and the **video clip lives on the car's USB**
  — it is not available through TeslaMate or this service.
- Tesla does not expose battery **pack temperature** to third parties, so it isn't
  available in TeslaMate or here.
# Charge-cost reminders (5.6.0)

Set `HISTORY_API_URL` to your TeslaMateAPI base URL (without `/v1`) and, if needed,
`HISTORY_API_AUTHORIZATION` to its Authorization header. Keep credentials in the
server environment, never Git. Persist `charge-reminders.json` with the token files.
The bridge checks the most recent charge page every 30 seconds for each MQTT vehicle.
Its first successful check establishes a baseline without historical alerts.
Subsequent completed charges at new, unpriced locations send an alert linking to
that charge. Explicit per-location prices, including zero/free charging, suppress it.
Open Tesstats after upgrading to synchronize those prices and notification preferences.

Upgrade/restart the running bridge as well as the iOS app: publishing an iOS build
does not deploy this server. `/healthz` must report `mqttConnected: true`,
`apnsConfigured: true`, and `apnsEnvironment: "production"` for TestFlight.
`chargeCostRemindersConfigured` indicates whether the history endpoint is configured.
Without a running bridge, new-charge detection runs only while iOS grants the app
execution. APNs delivery also depends on connectivity and the user's iOS/Focus settings;
neither local polling nor silent pushes guarantee continuous background execution.

## License

Part of Tesstats, licensed under the [GNU AGPL-3.0-only](../LICENSE). If you run a
modified version of this service for other people, the AGPL requires you to offer
them its source code.
