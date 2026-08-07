"""
Iridium SBD ground station — web console for a RockBLOCK 9603.

Two halves:

  * MO (mobile originated, device -> here). Ground Control POSTs each message
    that the RockBLOCK sends up. That webhook must answer 200 within 3 seconds
    or the delivery is retried with a doubling backoff for ~6 days, so it does
    nothing but validate, insert one row, and return.

  * MT (mobile terminated, here -> device). We POST to the RockBLOCK web
    service, which queues one message for the modem to collect on its next
    session. Every send costs an Iridium credit, so it is behind a login.

API contract (docs.groundcontrol.com):
  MT  POST https://rockblock.rock7.com/rockblock/MT
      imei, username, password, data (hex), optional flush
      -> "OK,<mtId>"  or  "FAILED,<code>,<description>"
  MO  form-encoded POST with imei, serial, momsn, transmit_time,
      iridium_latitude, iridium_longitude, iridium_cep, data (hex), JWT
"""

import binascii
import functools
import json
import os
import queue
import secrets
import sqlite3
import threading
import time
from contextlib import contextmanager
from datetime import datetime, timezone

import requests
from flask import (Flask, g, has_app_context, jsonify, redirect,
                   render_template, request, session, url_for)
from werkzeug.middleware.proxy_fix import ProxyFix

try:
    import paho.mqtt.client as mqtt
except ImportError:          # MQTT is optional; the rest of the app still runs
    mqtt = None

# --------------------------------------------------------------------------
# Config
# --------------------------------------------------------------------------

DB_PATH   = os.environ.get("DB_PATH", "/data/iridium.db")
MT_URL    = os.environ.get("ROCKBLOCK_MT_URL", "https://rockblock.rock7.com/rockblock/MT")

# A RockBLOCK MT message maxes out at 270 bytes. The board's firmware only
# stores and shows the first 50, so anything longer still arrives but is
# truncated on the OLED — the UI warns about that rather than blocking it.
MT_MAX_BYTES     = 270
DEVICE_SHOWS     = 50
MT_TIMEOUT_S     = 30

app = Flask(__name__)
app.secret_key = os.environ.get("SECRET_KEY") or secrets.token_hex(32)
app.config.update(SESSION_COOKIE_HTTPONLY=True, SESSION_COOKIE_SAMESITE="Lax")

# Behind nginx. x_prefix honours X-Forwarded-Prefix, which is what lets the app
# be mounted under a sub-path (/iridium/) without any hard-coded path: url_for()
# and request.url_root both come out with the prefix, so the webhook URL shown
# on the dashboard is the one Ground Control should actually be given.
# x_proto is what makes redirects and the secure cookie say https rather than
# http, since TLS is terminated at nginx.
app.wsgi_app = ProxyFix(app.wsgi_app, x_for=1, x_proto=1, x_host=1, x_prefix=1)

# Only send the session cookie over HTTPS when we are actually behind TLS.
if os.environ.get("BEHIND_TLS", "").lower() in ("1", "true", "yes"):
    app.config.update(SESSION_COOKIE_SECURE=True)


# --------------------------------------------------------------------------
# Storage
# --------------------------------------------------------------------------

def _connect():
    """A fresh connection. SQLite connections are not shareable across threads,
    so the MQTT worker opens its own rather than borrowing the request one."""
    os.makedirs(os.path.dirname(DB_PATH) or ".", exist_ok=True)
    conn = sqlite3.connect(DB_PATH, timeout=10)
    conn.row_factory = sqlite3.Row
    # The webhook and the dashboard write concurrently; WAL keeps a reader
    # from blocking the 3-second webhook deadline.
    conn.execute("PRAGMA journal_mode=WAL")
    conn.execute("PRAGMA busy_timeout=5000")
    return conn


def db():
    if "db" not in g:
        g.db = _connect()
    return g.db


@contextmanager
def any_db():
    """Request connection when there is one, otherwise a short-lived private
    connection. Lets the same helpers serve both HTTP handlers and threads."""
    if has_app_context():
        yield db()
    else:
        conn = _connect()
        try:
            yield conn
        finally:
            conn.close()


@app.teardown_appcontext
def _close_db(_exc):
    conn = g.pop("db", None)
    if conn is not None:
        conn.close()


SCHEMA = """
CREATE TABLE IF NOT EXISTS messages (
    id            INTEGER PRIMARY KEY AUTOINCREMENT,
    direction     TEXT    NOT NULL,          -- 'MO' (from device) | 'MT' (to device)
    imei          TEXT,
    momsn         INTEGER,                   -- MO sequence number
    mtid          TEXT,                      -- MT id returned by RockBLOCK
    text          TEXT,                      -- decoded, if it is printable
    hex           TEXT,                      -- raw payload as hex
    nbytes        INTEGER,
    lat           REAL,
    lon           REAL,
    cep           REAL,                      -- position accuracy, km
    transmit_time TEXT,                      -- UTC, as reported by Iridium
    created_at    INTEGER NOT NULL,          -- unix seconds, our clock
    status        TEXT,                      -- MT: OK / FAILED ...
    detail        TEXT
);
CREATE INDEX IF NOT EXISTS idx_messages_created ON messages(created_at DESC);

CREATE TABLE IF NOT EXISTS settings (
    key   TEXT PRIMARY KEY,
    value TEXT
);

CREATE TABLE IF NOT EXISTS events (
    id         INTEGER PRIMARY KEY AUTOINCREMENT,
    created_at INTEGER NOT NULL,
    kind       TEXT,
    detail     TEXT
);
CREATE INDEX IF NOT EXISTS idx_events_created ON events(created_at DESC);
"""

DEFAULT_SETTINGS = {
    "rockblock_user": os.environ.get("ROCKBLOCK_USER", ""),
    "rockblock_pass": os.environ.get("ROCKBLOCK_PASS", ""),
    "imei":           os.environ.get("ROCKBLOCK_IMEI", ""),
    # No hard-coded fallback: an unset ADMIN_PASSWORD gets a random one, printed
    # once to the container log at first start. A shipped default would be a
    # published credential the moment this repo is public.
    "admin_password": os.environ.get("ADMIN_PASSWORD") or secrets.token_urlsafe(12),
    "mqtt_enabled":    os.environ.get("MQTT_ENABLED", "0"),
    "mqtt_host":       os.environ.get("MQTT_HOST", ""),
    "mqtt_port":       os.environ.get("MQTT_PORT", "1883"),
    "mqtt_user":       os.environ.get("MQTT_USER", ""),
    "mqtt_pass":       os.environ.get("MQTT_PASS", ""),
    "mqtt_tls":        os.environ.get("MQTT_TLS", "0"),
    "mqtt_base":       os.environ.get("MQTT_BASE", "iridium"),
    # Inbound remote-send is OFF by default: anything that can publish to the
    # command topic can spend Iridium credits.
    "mqtt_allow_send": os.environ.get("MQTT_ALLOW_SEND", "0"),
}


def init_db():
    # Runs at import, before any request, so it cannot rely on db() having
    # already created the directory.
    parent = os.path.dirname(DB_PATH)
    if parent:
        os.makedirs(parent, exist_ok=True)
    conn = sqlite3.connect(DB_PATH, timeout=10)
    conn.executescript(SCHEMA)
    fresh = []
    for k, v in DEFAULT_SETTINGS.items():
        cur = conn.execute(
            "INSERT OR IGNORE INTO settings(key,value) VALUES(?,?)", (k, v))
        if cur.rowcount:
            fresh.append(k)
    conn.commit()
    conn.close()

    # Surface a generated password once, or it is unknowable.
    if "admin_password" in fresh and not os.environ.get("ADMIN_PASSWORD"):
        print("=" * 62, flush=True)
        print("  ADMIN_PASSWORD was not set. Generated a random one:", flush=True)
        print(f"      {DEFAULT_SETTINGS['admin_password']}", flush=True)
        print("  Sign in with it, then change it in Settings.", flush=True)
        print("=" * 62, flush=True)


def setting(key, default=""):
    with any_db() as conn:
        row = conn.execute("SELECT value FROM settings WHERE key=?", (key,)).fetchone()
    return row["value"] if row and row["value"] is not None else default


def set_setting(key, value):
    with any_db() as conn:
        conn.execute(
            "INSERT INTO settings(key,value) VALUES(?,?) "
            "ON CONFLICT(key) DO UPDATE SET value=excluded.value", (key, value))
        conn.commit()


def flag(key, default=False):
    return str(setting(key, "1" if default else "0")).lower() in ("1", "true", "yes", "on")


def log_event(kind, detail):
    with any_db() as conn:
        conn.execute("INSERT INTO events(created_at,kind,detail) VALUES(?,?,?)",
                     (int(time.time()), kind, detail))
        conn.commit()


# --------------------------------------------------------------------------
# Helpers
# --------------------------------------------------------------------------

def hex_to_text(hex_str):
    """Decode a hex payload to text when it is printable, else return None."""
    try:
        raw = binascii.unhexlify(hex_str)
    except (binascii.Error, TypeError, ValueError):
        return None, 0
    try:
        txt = raw.decode("utf-8")
    except UnicodeDecodeError:
        return None, len(raw)
    # Control characters mean it is binary telemetry, not a human message.
    if any(ord(c) < 0x20 and c not in "\r\n\t" for c in txt):
        return None, len(raw)
    return txt, len(raw)


def login_required(fn):
    @functools.wraps(fn)
    def wrapper(*a, **kw):
        if not session.get("auth"):
            if request.path.startswith("/api/"):
                return jsonify(error="not authenticated"), 401
            return redirect(url_for("login", next=request.path))
        return fn(*a, **kw)
    return wrapper


def utcnow_iso():
    return datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M:%S")


# --------------------------------------------------------------------------
# MQTT bridge
# --------------------------------------------------------------------------
#
# Topics, under the configurable base (default "iridium"):
#
#   <base>/status   retained "online"/"offline"  (offline is the LWT)
#   <base>/mo       JSON, one per message received from the device
#   <base>/mt       JSON, one per message queued to the device (incl. failures)
#   <base>/send     SUBSCRIBED, optional: publish text here to queue an MT
#
# Two things shape this design:
#
#   * The MO webhook has a 3-second budget. publish() with QoS 0 only hands the
#     packet to paho's network thread and returns, so a dead broker slows
#     nothing down — but the client must never be constructed on that path.
#   * Anything able to publish to <base>/send can spend real money, so the
#     subscription only exists when mqtt_allow_send is explicitly turned on.

_mqtt_client = None
_mqtt_lock = threading.Lock()
_mqtt_state = {"connected": False, "error": "", "since": None}

# MQTT commands are executed on our own worker thread: send_mt() blocks on an
# HTTP call for up to 30 s and must not stall paho's network loop.
_cmd_q = queue.Queue(maxsize=32)


def mqtt_topic(suffix):
    return f"{setting('mqtt_base', 'iridium').strip('/')}/{suffix}"


def mqtt_publish(suffix, payload, retain=False):
    """Fire-and-forget. Safe to call from the webhook: never blocks, never raises."""
    client = _mqtt_client
    if client is None or not _mqtt_state["connected"]:
        return
    try:
        body = payload if isinstance(payload, str) else json.dumps(payload, default=str)
        client.publish(mqtt_topic(suffix), body, qos=0, retain=retain)
    except Exception as exc:                     # never break a request over MQTT
        app.logger.warning("mqtt publish failed: %s", exc)


def _cmd_worker():
    while True:
        text = _cmd_q.get()
        try:
            ok, res = send_mt(text, source="mqtt")
            app.logger.info("mqtt send %s: %s", "ok" if ok else "failed",
                            res.get("detail") or res.get("error"))
        except Exception as exc:
            app.logger.exception("mqtt command failed: %s", exc)
        finally:
            _cmd_q.task_done()


threading.Thread(target=_cmd_worker, daemon=True, name="mqtt-cmd").start()


def _on_connect(client, userdata, flags, rc, properties=None):
    ok = (getattr(rc, "value", rc) == 0)
    _mqtt_state.update(connected=ok, since=int(time.time()),
                       error="" if ok else f"connect rc={rc}")
    if not ok:
        return
    client.publish(mqtt_topic("status"), "online", qos=0, retain=True)
    if flag("mqtt_allow_send"):
        client.subscribe(mqtt_topic("send"), qos=1)
        app.logger.info("mqtt subscribed to %s", mqtt_topic("send"))


def _on_disconnect(client, userdata, rc, properties=None, reason=None):
    _mqtt_state.update(connected=False, error=f"disconnected rc={rc}")


def _on_message(client, userdata, msg):
    if not flag("mqtt_allow_send"):
        return                                   # setting turned off since subscribe
    text = msg.payload.decode("utf-8", "replace").strip()
    # Accept a bare string or {"text": "..."} so either style of publisher works.
    if text.startswith("{"):
        try:
            text = str(json.loads(text).get("text", "")).strip()
        except (ValueError, AttributeError):
            pass
    if not text:
        return
    try:
        _cmd_q.put_nowait(text)
    except queue.Full:
        app.logger.warning("mqtt command queue full, dropped: %r", text[:40])


def mqtt_stop():
    global _mqtt_client
    with _mqtt_lock:
        if _mqtt_client is not None:
            try:
                _mqtt_client.publish(mqtt_topic("status"), "offline", qos=0, retain=True)
                _mqtt_client.disconnect()
                _mqtt_client.loop_stop()
            except Exception:
                pass
            _mqtt_client = None
        _mqtt_state.update(connected=False, error="", since=None)


def mqtt_start():
    """(Re)connect using the stored settings. Idempotent; safe to call anytime."""
    global _mqtt_client
    mqtt_stop()

    if mqtt is None:
        _mqtt_state["error"] = "paho-mqtt is not installed"
        return
    if not flag("mqtt_enabled"):
        return
    host = setting("mqtt_host").strip()
    if not host:
        _mqtt_state["error"] = "no broker host set"
        return

    try:
        port = int(setting("mqtt_port", "1883") or 1883)
    except ValueError:
        port = 1883

    with _mqtt_lock:
        try:
            client = mqtt.Client(
                mqtt.CallbackAPIVersion.VERSION2,
                client_id=f"iridium-web-{secrets.token_hex(4)}",
                clean_session=True)
            user, pw = setting("mqtt_user"), setting("mqtt_pass")
            if user:
                client.username_pw_set(user, pw or None)
            if flag("mqtt_tls"):
                client.tls_set()
            client.on_connect = _on_connect
            client.on_disconnect = _on_disconnect
            client.on_message = _on_message
            # If we die, the broker publishes 'offline' for us.
            client.will_set(mqtt_topic("status"), "offline", qos=0, retain=True)
            client.reconnect_delay_set(min_delay=2, max_delay=60)
            # connect_async + loop_start so a dead broker cannot block startup.
            client.connect_async(host, port, keepalive=45)
            client.loop_start()
            _mqtt_client = client
            _mqtt_state["error"] = ""
        except Exception as exc:
            _mqtt_state.update(connected=False, error=f"{exc.__class__.__name__}: {exc}")
            app.logger.warning("mqtt start failed: %s", exc)


# --------------------------------------------------------------------------
# MO webhook — Ground Control posts here
# --------------------------------------------------------------------------

def webhook_payload():
    """
    Ground Control posts either form-encoded (delivery type HTTP_POST) or JSON
    (HTTP_JSON), chosen per delivery address in RockBLOCK Core. Accept both.

    Their docs list the same field names for either variant but do not pin down
    whether numbers arrive as JSON numbers or as strings, so nothing here reads
    a value directly — every field goes through a coercion helper below.
    """
    if request.form:
        return request.form

    data = request.get_json(silent=True)
    if data is None:
        # Parse anyway if the Content-Type is missing or mislabelled.
        data = request.get_json(silent=True, force=True)

    if isinstance(data, dict):
        # Tolerate an envelope: if the known keys are not at the top level,
        # look one level down before giving up.
        if "imei" not in data:
            for value in data.values():
                if isinstance(value, dict) and "imei" in value:
                    return value
        return data
    return {}


@app.post("/rockblock/mo")
def rockblock_mo():
    """
    Deliberately minimal: validate, insert, return 200. No outbound calls, no
    template rendering — Ground Control gives us 3 seconds before it treats the
    delivery as failed and starts retrying.
    """
    src = webhook_payload()

    imei = str(src.get("imei", "")).strip()
    if not imei:
        return "missing imei", 400

    # If an IMEI is configured, refuse anything else. The endpoint is public by
    # necessity, so this stops a stranger seeding the database.
    expected = setting("imei", "").strip()
    if expected and imei != expected:
        log_event("mo_rejected", f"unexpected imei {imei}")
        return "unknown imei", 403

    data_hex = str(src.get("data", "") or "")
    text, nbytes = hex_to_text(data_hex)

    def num(key):
        try:
            return float(src.get(key))
        except (TypeError, ValueError):
            return None

    def integer(key):
        try:
            return int(src.get(key))
        except (TypeError, ValueError):
            return None

    row = {
        "imei": imei, "momsn": integer("momsn"), "text": text, "hex": data_hex,
        "nbytes": nbytes, "lat": num("iridium_latitude"),
        "lon": num("iridium_longitude"), "cep": num("iridium_cep"),
        "transmit_time": str(src.get("transmit_time", "") or ""),
        "received_at": int(time.time()),
    }

    db().execute(
        "INSERT INTO messages(direction,imei,momsn,text,hex,nbytes,lat,lon,cep,"
        "transmit_time,created_at,status) "
        "VALUES('MO',?,?,?,?,?,?,?,?,?,?, 'received')",
        (row["imei"], row["momsn"], row["text"], row["hex"], row["nbytes"],
         row["lat"], row["lon"], row["cep"], row["transmit_time"],
         row["received_at"]))
    db().commit()

    # Hands the packet to paho's network thread and returns; a dead broker
    # cannot push us past the 3-second deadline.
    mqtt_publish("mo", row)

    # 200 with a short body: anything else and it will be redelivered.
    return "OK", 200


@app.get("/healthz")
def healthz():
    return "ok", 200


# --------------------------------------------------------------------------
# Auth
# --------------------------------------------------------------------------

@app.route("/login", methods=["GET", "POST"])
def login():
    error = None
    if request.method == "POST":
        supplied = request.form.get("password", "")
        if secrets.compare_digest(supplied, setting("admin_password")):
            session["auth"] = True
            session.permanent = False
            log_event("login", request.remote_addr or "?")
            return redirect(request.args.get("next") or url_for("index"))
        error = "Wrong password."
        log_event("login_failed", request.remote_addr or "?")
        time.sleep(1)               # blunt the guessing rate
    return render_template("login.html", error=error)


@app.get("/logout")
def logout():
    session.clear()
    return redirect(url_for("login"))


# --------------------------------------------------------------------------
# Dashboard
# --------------------------------------------------------------------------

@app.get("/")
@login_required
def index():
    return render_template("index.html",
                           mt_max=MT_MAX_BYTES,
                           device_shows=DEVICE_SHOWS)


@app.get("/api/state")
@login_required
def api_state():
    rows = db().execute(
        "SELECT * FROM messages ORDER BY created_at DESC, id DESC LIMIT 200"
    ).fetchall()
    msgs = [dict(r) for r in rows]

    last_mo = next((m for m in msgs if m["direction"] == "MO"), None)
    last_mt = next((m for m in msgs if m["direction"] == "MT"), None)

    mo_total = db().execute(
        "SELECT COUNT(*) c FROM messages WHERE direction='MO'").fetchone()["c"]
    mt_total = db().execute(
        "SELECT COUNT(*) c FROM messages WHERE direction='MT'").fetchone()["c"]

    configured = bool(setting("rockblock_user") and setting("rockblock_pass")
                      and setting("imei"))

    return jsonify(
        imei=setting("imei"),
        configured=configured,
        mqtt={
            "enabled":    flag("mqtt_enabled"),
            "connected":  _mqtt_state["connected"],
            "error":      _mqtt_state["error"],
            "host":       setting("mqtt_host"),
            "port":       setting("mqtt_port", "1883"),
            "base":       setting("mqtt_base", "iridium"),
            "allow_send": flag("mqtt_allow_send"),
        },
        mo_total=mo_total,
        mt_total=mt_total,
        last_mo=last_mo,
        last_mt=last_mt,
        server_time=utcnow_iso(),
        webhook_url=request.url_root.rstrip("/") + "/rockblock/mo",
        messages=msgs,
    )


def send_mt(text, source="web"):
    """
    Queue one mobile-terminated message with the RockBLOCK web service.

    Shared by the web UI and the MQTT command topic, and callable from a plain
    thread — it takes no Flask request state. Returns (ok, result_dict).
    Costs one Iridium credit per 50 bytes, so callers must be authorised.
    """
    text = (text or "").strip()
    if not text:
        return False, {"error": "message is empty"}

    raw = text.encode("utf-8")
    if len(raw) > MT_MAX_BYTES:
        return False, {"error": f"message is {len(raw)} bytes, "
                                f"limit is {MT_MAX_BYTES}"}

    user, pw, imei = (setting("rockblock_user"), setting("rockblock_pass"),
                      setting("imei"))
    if not (user and pw and imei):
        return False, {"error": "RockBLOCK credentials are not set — open Settings"}

    hexed = binascii.hexlify(raw).decode()
    try:
        resp = requests.post(
            MT_URL,
            data={"imei": imei, "username": user, "password": pw, "data": hexed},
            timeout=MT_TIMEOUT_S,
        )
        body = resp.text.strip()
    except requests.RequestException as exc:
        body = f"FAILED,-1,{exc.__class__.__name__}: {exc}"

    # "OK,<mtId>"  or  "FAILED,<code>,<description>"
    parts = body.split(",")
    ok = parts[0].upper() == "OK"
    mtid = parts[1] if ok and len(parts) > 1 else None
    detail = f"queued as {mtid}" if ok else body

    with any_db() as conn:
        conn.execute(
            "INSERT INTO messages(direction,imei,mtid,text,hex,nbytes,created_at,"
            "status,detail) VALUES('MT',?,?,?,?,?,?,?,?)",
            (imei, mtid, text, hexed, len(raw), int(time.time()),
             "queued" if ok else "failed", detail))
        conn.commit()
    log_event("mt_send", f"[{source}] {'OK' if ok else 'FAIL'}: {detail}")

    result = {"ok": ok, "mtid": mtid, "bytes": len(raw), "text": text,
              "source": source, "detail": detail,
              "truncated_on_device": len(raw) > DEVICE_SHOWS}
    mqtt_publish("mt", result)
    if not ok:
        result["error"] = detail
        result["raw"] = body
    return ok, result


@app.post("/api/send")
@login_required
def api_send():
    payload = request.get_json(silent=True) or {}
    ok, result = send_mt(payload.get("text"), source="web")
    if not ok:
        # A validation problem is the caller's fault; anything else came back
        # from RockBLOCK, so report it as an upstream failure.
        code = 400 if result.get("mtid") is None and "error" in result \
                      and not result.get("raw") else 502
        return jsonify(result), code
    return jsonify(result)


@app.route("/api/settings", methods=["GET", "POST"])
@login_required
def api_settings():
    if request.method == "POST":
        payload = request.get_json(silent=True) or {}
        for key in ("rockblock_user", "imei",
                    "mqtt_host", "mqtt_port", "mqtt_user", "mqtt_base"):
            if key in payload:
                set_setting(key, str(payload[key]).strip())
        for key in ("mqtt_enabled", "mqtt_tls", "mqtt_allow_send"):
            if key in payload:
                set_setting(key, "1" if payload[key] else "0")
        # Blank password fields mean "leave the stored one alone", so secrets
        # never have to be echoed back to the browser.
        if payload.get("rockblock_pass"):
            set_setting("rockblock_pass", str(payload["rockblock_pass"]))
        if payload.get("admin_password"):
            set_setting("admin_password", str(payload["admin_password"]))
        if payload.get("mqtt_pass"):
            set_setting("mqtt_pass", str(payload["mqtt_pass"]))
        log_event("settings", "updated")

        # Reconnect if anything MQTT-related moved. Also picks up a changed
        # allow_send, which decides whether we subscribe at all.
        if any(k.startswith("mqtt_") for k in payload):
            threading.Thread(target=mqtt_start, daemon=True).start()
        return jsonify(ok=True)

    return jsonify(
        rockblock_user=setting("rockblock_user"),
        imei=setting("imei"),
        has_password=bool(setting("rockblock_pass")),
        webhook_url=request.url_root.rstrip("/") + "/rockblock/mo",
        mqtt_enabled=flag("mqtt_enabled"),
        mqtt_host=setting("mqtt_host"),
        mqtt_port=setting("mqtt_port", "1883"),
        mqtt_user=setting("mqtt_user"),
        mqtt_has_password=bool(setting("mqtt_pass")),
        mqtt_tls=flag("mqtt_tls"),
        mqtt_base=setting("mqtt_base", "iridium"),
        mqtt_allow_send=flag("mqtt_allow_send"),
        mqtt_connected=_mqtt_state["connected"],
        mqtt_error=_mqtt_state["error"],
        mqtt_topics={
            "status": mqtt_topic("status"), "mo": mqtt_topic("mo"),
            "mt": mqtt_topic("mt"), "send": mqtt_topic("send"),
        },
    )


@app.get("/api/events")
@login_required
def api_events():
    rows = db().execute(
        "SELECT * FROM events ORDER BY created_at DESC LIMIT 100").fetchall()
    return jsonify(events=[dict(r) for r in rows])


init_db()
mqtt_start()          # no-op unless enabled; connect_async never blocks boot

if __name__ == "__main__":
    app.run(host="0.0.0.0", port=8899, debug=False)
