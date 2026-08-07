# Iridium ground station

Web console for a **RockBLOCK 9603** Iridium Short Burst Data modem. Shows what
the device has sent, where it was when it sent it, and lets you queue messages
back to it.

Companion to the ESP32-S3 firmware and the Android app in the sibling repos.

## How the two directions actually work

**MO — device → here.** The RockBLOCK transmits to an Iridium satellite, which
lands the message at Ground Control, which POSTs it to a webhook you nominate.
There is no polling and no API to "fetch messages" — if you do not run a
reachable endpoint, the messages go nowhere.

```
POST /rockblock/mo
  imei, serial, momsn, transmit_time,
  iridium_latitude, iridium_longitude, iridium_cep,
  data (hex-encoded), JWT
```

Both delivery types are accepted: **HTTP_POST** (form-encoded) and **HTTP_JSON**
(`application/json`), whichever you pick per delivery address in RockBLOCK Core.
Ground Control's docs list the same field names for both but do not state
whether numbers arrive as JSON numbers or strings, so every field is coerced
rather than read directly. A JSON body with a missing or wrong `Content-Type` is
parsed anyway, and an enveloped payload is unwrapped one level.

That endpoint must return **HTTP 200 within 3 seconds**. Miss it and Ground
Control retries with a doubling backoff for about six days. This app therefore
validates, writes one row, and returns — no outbound calls on that path. It
answers in ~15 ms.

**MT — here → device.** Posting to the RockBLOCK web service *queues* a message.
The modem only collects it during its **next session**: when it next transmits,
or when a ring alert prompts it to check in. It is not a push.

```
POST https://rockblock.rock7.com/rockblock/MT
  imei, username, password, data (hex), [flush]
  -> "OK,<mtId>"  |  "FAILED,<code>,<description>"
```

## Sizes

| | Limit |
|---|---|
| MT message (what this app sends) | 270 bytes |
| MO message (what the device sends) | 340 bytes, but the firmware uses 50 |
| Billing | one credit per 50 bytes |
| Shown on the device's OLED | first 50 bytes only |

Send more than 50 bytes and it still arrives — the board just displays the
first 50, because its firmware caps `lastRx` at `RX_TEXT_MAX`. The UI warns
about this rather than blocking it.

## Deploying

Flask + SQLite + Gunicorn in Docker, data in a named volume, sitting behind
nginx with TLS.

```sh
docker compose up -d --build
```

The container binds **loopback only** (`127.0.0.1:8890`) and nginx proxies it at
`https://<host>/iridium/`. Nothing is published to the internet directly — see
`DEPLOY.md` and `nginx/iridium.conf`.

The app is mounted under a sub-path, so the proxy must send
`X-Forwarded-Prefix` and `X-Forwarded-Proto`. Without them it still runs, but
every redirect and the webhook URL it displays come out wrong. It also works
unproxied at `/` with no configuration change.

Set these in `docker-compose.yml` before first run:

* `SECRET_KEY` — any long random string. Changing it logs everyone out.
* `ADMIN_PASSWORD` — first-run console password, changeable later in Settings.

RockBLOCK credentials are deliberately **not** required as environment
variables. Leave them empty and enter them in the app's **Settings** tab, so
the password never sits in a compose file or a shell history.

### Wiring up the webhook

1. Sign in to the Ground Control / RockBLOCK Core portal.
2. Your device → Delivery Groups → add a delivery address, either
   **HTTP_JSON** or **HTTP_POST**.
3. Point it at `https://<host>/iridium/rockblock/mo`.

The endpoint must be reachable from the public internet. The dashboard shows
the exact URL to paste, derived from the proxy headers.

## MQTT bridge

Optional, off by default, configured in the Settings tab. Topics sit under a
configurable base (default `iridium`):

| Topic | Direction | Payload |
|---|---|---|
| `iridium/status` | out, **retained** | `online` / `offline` (`offline` is the LWT) |
| `iridium/mo` | out | JSON of each message received from the device |
| `iridium/mt` | out | JSON of each message queued to the device, successes and failures |
| `iridium/send` | **in**, optional | text to transmit — accepts a bare string or `{"text": "..."}` |

```json
// iridium/mo
{"imei":"3002340...","momsn":101,"text":"SOS need assistance",
 "hex":"534f53...","nbytes":19,"lat":13.7563,"lon":100.5018,"cep":3.0,
 "transmit_time":"26-08-07 13:05:00","received_at":1786...}
```

`iridium/mt` carries a `source` field (`web` or `mqtt`) so a subscriber can tell
who initiated a send.

### Two things this design is careful about

**The webhook deadline.** Publishing uses QoS 0, which only hands the packet to
paho's network thread and returns. Measured with the broker deliberately killed,
the MO webhook still answered in **9 ms** — a dead broker cannot push it past
Ground Control's 3-second limit.

**Remote send costs money.** Anything that can publish to `iridium/send` can
transmit on your account, so that subscription only exists when
**Allow sending from MQTT** is explicitly enabled. With it off, the client never
subscribes at all — verified by publishing a command and confirming nothing
reached the RockBLOCK API. Only enable it on a broker you control that requires
authentication.

**One Gunicorn worker.** The container runs `-w 1 --threads 8` on purpose. With
two workers, both processes would subscribe to the command topic and a single
inbound message would be sent twice — two Iridium credits for one message.

## Security notes

* Every MT send **costs credits**, so the whole console is behind a login and
  the send button asks for confirmation.
* The webhook cannot be authenticated with a password (Ground Control decides
  what it posts), so it rejects any message whose `imei` does not match the
  configured device. Set the IMEI in Settings before going live.
* Ground Control also signs each delivery with a `JWT` field verifiable against
  their RSA public key. This app does not check it yet — the IMEI match is the
  current defence. Worth adding if the endpoint is ever widely known.
* TLS terminates at nginx and the container is loopback-only, so the console
  password never crosses the network in clear. `BEHIND_TLS=true` marks the
  session cookie `Secure`; turn it off if you ever run without TLS or you will
  not be able to log in.
* Do **not** change the port mapping to `8890:8899`. Docker writes its own
  iptables rules, so a published port is reachable from the internet even when
  the host firewall says otherwise — that would expose the console on plain
  HTTP and bypass nginx entirely.

## Endpoints

| Route | Auth | Purpose |
|---|---|---|
| `GET /` | session | dashboard |
| `POST /rockblock/mo` | IMEI match | Ground Control delivery webhook |
| `GET /api/state` | session | status, counters, message history |
| `POST /api/send` | session | queue an MT message |
| `GET/POST /api/settings` | session | credentials, IMEI, passwords |
| `GET /healthz` | none | container healthcheck |

## Stack

Python 3.12 · Flask · SQLite (WAL) · Gunicorn (**1 worker**, 8 threads — see the
MQTT note above) · paho-mqtt · vanilla JS front end, no CDN.
