"""
Generate the Node-RED flow for receiving Ground Control MO messages.

Written as a generator rather than hand-edited JSON because function-node code
has to be JSON-escaped, and hand-escaping newlines is how flows end up
un-importable.
"""
import json
import pathlib
import sys

# argv: [label] [id-prefix] [outfile]
LABEL  = sys.argv[1] if len(sys.argv) > 1 else "Iridium Ground Control"
PREFIX = sys.argv[2] if len(sys.argv) > 2 else "n"
OUTFILE = sys.argv[3] if len(sys.argv) > 3 else "iridium-ground-control.json"
TAB = f"{PREFIX}.tab"

PARSE = r"""
// Ground Control MO delivery (HTTP_JSON or form-encoded).
//
// Fields: imei, serial, momsn, transmit_time, iridium_latitude,
//         iridium_longitude, iridium_cep, data (HEX), JWT
//
// The docs do not state whether numbers arrive as JSON numbers or as strings,
// and the form-encoded delivery type sends strings, so coerce everything
// rather than reading values directly.

const src = msg.payload || {};

const num = v => { const n = parseFloat(v); return isNaN(n) ? null : n; };
const int = v => { const n = parseInt(v, 10); return isNaN(n) ? null : n; };

const imei = String(src.imei || "").trim();
if (!imei) {
    node.warn("MO delivery with no imei - ignored");
    return null;
}

// The endpoint is public by necessity, so refuse anything that is not the
// configured device. Set the IMEI in the "config" node at the top of the flow.
const expected = String(flow.get("imei") || "").trim();
if (expected && imei !== expected) {
    node.warn("rejected MO from unexpected imei " + imei);
    return null;
}

// data is hex-encoded; decode it only if the result is printable text,
// otherwise keep the hex and treat it as binary telemetry.
let text = null, nbytes = 0;
const hex = String(src.data || "");
if (hex) {
    const buf = Buffer.from(hex, "hex");
    nbytes = buf.length;
    const s = buf.toString("utf8");
    if (/^[\x20-\x7E\r\n\t]*$/.test(s)) { text = s; }
}

const rec = {
    imei: imei,
    momsn: int(src.momsn),
    text: text,
    hex: hex,
    nbytes: nbytes,
    lat: num(src.iridium_latitude),
    lon: num(src.iridium_longitude),
    cep: num(src.iridium_cep),
    transmit_time: src.transmit_time || "",
    received_at: new Date().toISOString()
};

// Keep the most recent 100 in flow context.
const hist = flow.get("mo_history") || [];
hist.unshift(rec);
if (hist.length > 100) { hist.length = 100; }
flow.set("mo_history", hist);
flow.set("mo_count", (flow.get("mo_count") || 0) + 1);

node.status({ fill: "green", shape: "dot",
              text: (text || hex).substring(0, 24) + "  #" + rec.momsn });

msg.topic = "iridium/mo";
msg.payload = rec;
return msg;
"""

CONFIG = r"""
// Set your device IMEI here, then Deploy. Leave blank to accept any sender
// (not recommended - the webhook is publicly reachable).
flow.set("imei", "");
node.status({ fill: "blue", shape: "ring",
              text: "imei " + (flow.get("imei") || "(any)") });
return null;
"""

HISTORY = r"""
// Serve the stored messages as JSON for a quick look in a browser.
msg.payload = {
    count: flow.get("mo_count") || 0,
    imei: flow.get("imei") || null,
    messages: flow.get("mo_history") || []
};
return msg;
"""

SAMPLE = {
    "imei": "300234060000000",
    "momsn": 101,
    "transmit_time": "26-08-07 13:05:00",
    "iridium_latitude": 13.7563,
    "iridium_longitude": 100.5018,
    "iridium_cep": 3,
    "data": "534f53206e65656420617373697374616e6365",
}

flow = [
    {"id": TAB, "type": "tab", "label": LABEL,
     "disabled": False,
     "info": "Receives Mobile Originated messages from Ground Control "
             "(RockBLOCK / Iridium SBD).\n\n"
             "Delivery address to set in RockBLOCK Core:\n"
             "  http://<this-host>:1880/rockblock/mo\n\n"
             "Ground Control requires HTTP 200 within 3 seconds or it retries "
             "with a doubling backoff for about six days, so the response is "
             "sent immediately and parsing happens on a separate branch.\n\n"
             "Set your IMEI in the 'set imei' node, then Deploy."},

    # --- config ---------------------------------------------------------
    {"id": "n_cfg_inj", "type": "inject", "z": TAB, "name": "on start",
     "props": [{"p": "payload"}], "repeat": "", "crontab": "", "once": True,
     "onceDelay": "0.1", "topic": "", "payload": "", "payloadType": "date",
     "x": 130, "y": 60, "wires": [["n_cfg"]]},
    {"id": "n_cfg", "type": "function", "z": TAB, "name": "set imei",
     "func": CONFIG, "outputs": 1, "noerr": 0, "initialize": "", "finalize": "",
     "libs": [], "x": 300, "y": 60, "wires": [[]]},

    # --- webhook --------------------------------------------------------
    {"id": "n_in", "type": "http in", "z": TAB, "name": "MO webhook",
     "url": "/rockblock/mo", "method": "post", "upload": False, "swaggerDoc": "",
     "x": 130, "y": 160, "wires": [["n_ok", "n_parse"]]},

    # Respond first, on its own branch: nothing downstream can delay the 200.
    {"id": "n_ok", "type": "change", "z": TAB, "name": "200 OK",
     "rules": [{"t": "set", "p": "payload", "pt": "msg", "to": "OK",
                "tot": "str"},
               {"t": "set", "p": "statusCode", "pt": "msg", "to": "200",
                "tot": "num"}],
     "action": "", "property": "", "from": "", "to": "", "reg": False,
     "x": 320, "y": 120, "wires": [["n_res"]]},
    {"id": "n_res", "type": "http response", "z": TAB, "name": "",
     "statusCode": "", "headers": {}, "x": 490, "y": 120, "wires": []},

    {"id": "n_parse", "type": "function", "z": TAB, "name": "parse MO",
     "func": PARSE, "outputs": 1, "noerr": 0, "initialize": "", "finalize": "",
     "libs": [], "x": 330, "y": 200, "wires": [["n_dbg"]]},
    {"id": "n_dbg", "type": "debug", "z": TAB, "name": "message",
     "active": True, "tosidebar": True, "console": False, "tostatus": False,
     "complete": "payload", "targetType": "msg", "statusVal": "",
     "statusType": "auto", "x": 520, "y": 200, "wires": []},

    # --- test without spending a credit ---------------------------------
    {"id": "n_test", "type": "inject", "z": TAB,
     "name": "test: fake a delivery",
     "props": [{"p": "payload"}], "repeat": "", "crontab": "", "once": False,
     "onceDelay": 0.1, "topic": "",
     "payload": json.dumps(SAMPLE), "payloadType": "json",
     "x": 160, "y": 260, "wires": [["n_parse"]]},

    # --- browse what has arrived ----------------------------------------
    {"id": "n_hist_in", "type": "http in", "z": TAB, "name": "GET messages",
     "url": "/rockblock/messages", "method": "get", "upload": False,
     "swaggerDoc": "", "x": 140, "y": 340, "wires": [["n_hist"]]},
    {"id": "n_hist", "type": "function", "z": TAB, "name": "history",
     "func": HISTORY, "outputs": 1, "noerr": 0, "initialize": "",
     "finalize": "", "libs": [], "x": 330, "y": 340, "wires": [["n_hist_res"]]},
    {"id": "n_hist_res", "type": "http response", "z": TAB, "name": "",
     "statusCode": "200", "headers": {}, "x": 500, "y": 340, "wires": []},

    # --- notes ----------------------------------------------------------
    {"id": "n_note", "type": "comment", "z": TAB,
     "name": "Set your IMEI in 'set imei', then Deploy",
     "info": "Delivery address for RockBLOCK Core:\n"
             "    http://<host>:1880/rockblock/mo\n\n"
             "View what has arrived:\n"
             "    http://<host>:1880/rockblock/messages\n\n"
             "The 200 is sent on its own branch so parsing can never push the "
             "response past Ground Control's 3-second limit.\n\n"
             "'data' is hex-encoded. It is decoded to text only when the result "
             "is printable, otherwise the hex is kept as-is.",
     "x": 220, "y": 20, "wires": []},
]

# Re-key every node so two generated flows can coexist in one Node-RED.
remap = {n["id"]: (n["id"] if n["type"] == "tab" else f"{PREFIX}.{n['id']}")
         for n in flow}
for n in flow:
    n["id"] = remap[n["id"]]
    if "wires" in n:
        n["wires"] = [[remap.get(w, w) for w in out_] for out_ in n["wires"]]

out = pathlib.Path(__file__).with_name(OUTFILE)
out.write_text(json.dumps(flow, indent=2), encoding="utf-8")
print(f"wrote {out}  label={LABEL!r}  ({len(flow)} nodes)")
