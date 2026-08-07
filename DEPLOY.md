# Deploying to the VPS (<your-host> / <vps-ip>)

SSH on :22 is filtered from outside, so the container is deployed through
**Portainer on :9443**, the same way the OTA server is managed. nginx and
certbot need a shell on the host.

The app is **not** exposed on a public port. It binds to `127.0.0.1:8890` and
nginx reverse-proxies it over TLS at:

```
https://<your-host>/iridium/
```

Ports on this host: `80` nginx · `443` nginx (TLS) · `8889` OTA server ·
`9443` Portainer. Nothing new needs opening.

---

## 1. Deploy the stack in Portainer

1. Open `https://<vps-ip>:9443` and sign in.
2. **Stacks → Add stack**, name it `iridium-web`.
3. Build method: **Repository**.
   * Repository URL: `https://github.com/Asteriskman2020/Iridium-Web`
   * Reference: `refs/heads/main`
   * Compose path: `docker-compose.yml`
   * The repo is **private**, so switch on **Authentication** and give your
     GitHub username plus a personal access token with `repo` scope.
4. Under **Environment variables**:

   | Name | Value |
   |---|---|
   | `SECRET_KEY` | `<paste a fresh random string>` |
   | `ADMIN_PASSWORD` | something only you know — **pick something only you know** |

5. **Deploy the stack.**

Leave `ROCKBLOCK_USER` / `ROCKBLOCK_PASS` / `ROCKBLOCK_IMEI` empty — those go in
the app's Settings tab, so the password never lands in a compose file or in
Portainer's stack definition.

Check it came up, from the host:

```sh
curl -s http://127.0.0.1:8890/healthz      # expect: ok
```

From anywhere else that must **fail** — the port is loopback-only by design.

---

## 2. Issue a TLS certificate

Port 443 is open but was not serving TLS. Let's Encrypt needs port 80 to answer
the HTTP-01 challenge, which nginx already does.

```sh
sudo apt install -y certbot python3-certbot-nginx
sudo certbot --nginx -d <your-host>
```

certbot edits the nginx config in place and installs a renewal timer. Confirm
renewal works:

```sh
sudo certbot renew --dry-run
```

---

## 3. Add the reverse proxy

`nginx/iridium.conf` in this repo is a complete server block. **If certbot has
already written a server block for <your-host> — which it will have — do not
add a second one.** Copy only the two `location` blocks (`/iridium/` and
`= /iridium`) into the existing `server { listen 443 ssl; ... }` block.

```sh
sudo nginx -t          # must pass before reloading
sudo systemctl reload nginx
```

Then:

```sh
curl -s https://<your-host>/iridium/healthz          # expect: ok
curl -sI http://<your-host>/iridium/ | head -1       # expect: 301 -> https
```

### Why the proxy headers matter

The app is mounted under a sub-path, so nginx must send:

```
proxy_set_header X-Forwarded-Prefix /iridium;
proxy_set_header X-Forwarded-Proto  $scheme;
```

`X-Forwarded-Prefix` is what makes Flask generate `/iridium/login` instead of
`/login`, and makes the dashboard display the correct webhook URL.
`X-Forwarded-Proto` is what makes it say `https://`. Drop either header and the
app still *runs*, but every redirect and the webhook address it shows you will
be wrong — which is a confusing failure, not an obvious one.

The trailing slash on `proxy_pass http://127.0.0.1:8890/;` is also load-bearing:
it strips `/iridium` before the request reaches the app. Remove it and every
route 404s.

---

## 4. Configure the app

Open `https://<your-host>/iridium/` and sign in with `ADMIN_PASSWORD`.

**Settings tab:**

* **Username / Password** — your Ground Control (RockBLOCK Core) portal login.
* **IMEI** — the 15-digit number on the RockBLOCK label. The webhook rejects
  deliveries from any other IMEI, so this is a security control. Set it before
  going live.

---

## 4b. MQTT (optional)

Settings tab → **MQTT bridge**. Enter the broker host/port, credentials if it
needs them, and a base topic. Saving reconnects immediately and the badge shows
`connected` or the error.

The bridge publishes `<base>/mo`, `<base>/mt` and a retained `<base>/status`.
Watch it with:

```sh
mosquitto_sub -h <broker> -t 'iridium/#' -v
```

**Allow sending from MQTT** is a separate switch and is off by default. Turning
it on subscribes to `<base>/send`, and anything able to publish there can
transmit on your account and spend credits. Only enable it on a broker you
control that requires authentication.

If the broker is unreachable the app keeps working normally — the MO webhook
still answers in single-digit milliseconds and sends still go out; only the
bridge is idle, and it reconnects on its own with backoff.

---

## 5. Point RockBLOCK at the webhook

Ground Control / RockBLOCK Core portal → **your device → Delivery Groups → add
a delivery address**. Either type works — **HTTP_JSON** (`application/json`) or
**HTTP_POST** (form-encoded); the handler accepts both:

```
https://<your-host>/iridium/rockblock/mo
```

Ground Control expects **HTTP 200 within 3 seconds** or it retries with a
doubling backoff for about six days. The handler answers in ~15 ms; the only
realistic failure is TLS or the proxy, so test it first — this costs no credits:

```sh
curl -m 10 -X POST https://<your-host>/iridium/rockblock/mo \
  -d "imei=<your imei>" -d "momsn=1" \
  -d "transmit_time=26-08-07 12:30:11" \
  -d "iridium_latitude=13.7563" -d "iridium_longitude=100.5018" \
  -d "iridium_cep=4" \
  -d "data=48656c6c6f"          # "Hello"
```

Or the JSON form, matching an HTTP_JSON delivery address:

```sh
curl -m 10 -X POST https://<your-host>/iridium/rockblock/mo   -H "Content-Type: application/json"   -d '{"imei":"<your imei>","momsn":1,"transmit_time":"26-08-07 12:30:11",
       "iridium_latitude":13.7563,"iridium_longitude":100.5018,
       "iridium_cep":4,"data":"48656c6c6f"}'
```

Expect `OK` and the message on the dashboard. `403 unknown imei` means the IMEI
in Settings does not match what you posted.

---

## 6. Updating later

Portainer → Stacks → `iridium-web` → **Pull and redeploy**.

History lives in the `iridium_data` volume, not the image, so it survives.

---

## Notes

* **Never publish the container port.** Docker writes its own iptables rules, so
  changing the mapping back to `8890:8899` would expose the console on plain
  HTTP to the internet *even if ufw says 8890 is closed*. The `127.0.0.1:` prefix
  in `docker-compose.yml` is the thing keeping it private.
* `BEHIND_TLS=true` marks the session cookie `Secure`. Leave it off if you ever
  run without TLS, or you will not be able to log in.
* Every MT send costs Iridium credits — hence the login and the confirm dialog.
