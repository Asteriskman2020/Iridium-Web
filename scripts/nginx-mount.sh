#!/usr/bin/env bash
#
# Mount this app under an existing nginx site, and prove it worked.
#
#   sudo ./scripts/nginx-mount.sh example.com            # pin the server_name
#   sudo ./scripts/nginx-mount.sh --force example.com    # re-target a bad mount
#   sudo ./scripts/nginx-mount.sh --remove               # undo
#   sudo ./scripts/nginx-mount.sh --dry-run example.com  # show, change nothing
#
# Pass the domain whenever you know it: a host can have several port-80 server
# blocks and only one of them answers for your name. Without it the script has
# to guess from default_server / catch-all, which is how a mount ends up live
# but never matching.
#
# It only considers blocks listening on 80 — a block listening solely on 443 is
# useless when another service already owns 443 — backs the file up, validates
# with `nginx -t`, restores on failure, and finally curls itself through nginx
# so the last line tells you PASS or FAIL rather than leaving you to guess.

set -euo pipefail

PREFIX=${IRIDIUM_PREFIX:-/iridium}
UPSTREAM=${IRIDIUM_UPSTREAM:-127.0.0.1:8890}
DOMAIN=""; DRY=0; FORCE=0; REMOVE=0
for a in "$@"; do
  case "$a" in
    --dry-run) DRY=1 ;;
    --force)   FORCE=1 ;;
    --remove)  REMOVE=1 ;;
    -*) echo "unknown option: $a"; exit 2 ;;
    *) DOMAIN="$a" ;;
  esac
done

command -v nginx   >/dev/null || { echo "nginx not found"; exit 1; }
command -v python3 >/dev/null || { echo "python3 required"; exit 1; }
[ "$(id -u)" -eq 0 ] || { echo "run with sudo"; exit 1; }

PREFIX="$PREFIX" UPSTREAM="$UPSTREAM" DOMAIN="$DOMAIN" \
DRY="$DRY" FORCE="$FORCE" REMOVE="$REMOVE" python3 <<'PY'
import os, re, shutil, subprocess, sys, time

PREFIX   = os.environ["PREFIX"].rstrip("/")
UPSTREAM = os.environ["UPSTREAM"]
DOMAIN   = os.environ["DOMAIN"]
DRY      = os.environ["DRY"]    == "1"
FORCE    = os.environ["FORCE"]  == "1"
REMOVE   = os.environ["REMOVE"] == "1"
MARK     = "Iridium ground station (managed)"

BLOCK = f"""
    # --- {MARK} ---
    location = {PREFIX} {{ return 301 {PREFIX}/; }}
    location {PREFIX}/ {{
        proxy_pass http://{UPSTREAM}/;
        proxy_http_version 1.1;
        proxy_set_header Host               $host;
        proxy_set_header X-Real-IP          $remote_addr;
        proxy_set_header X-Forwarded-For    $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto  $scheme;
        proxy_set_header X-Forwarded-Prefix {PREFIX};
        proxy_read_timeout 60s;
        proxy_buffering off;
    }}
    # --- end {MARK} ---
"""
BLOCK_RE = re.compile(r"\n?[ \t]*# --- " + re.escape(MARK) +
                      r" ---.*?# --- end " + re.escape(MARK) + r" ---\n?", re.S)

def sh(*a):
    return subprocess.run(a, capture_output=True, text=True)

def loaded_files():
    r = sh("nginx", "-T")
    if r.returncode:
        print("  ✗ `nginx -T` failed — the running config is already invalid:")
        print(r.stderr or r.stdout); sys.exit(1)
    return list(dict.fromkeys(re.findall(r"^# configuration file (.+?):$", r.stdout, re.M))), r.stdout

files, dump = loaded_files()
print(f"  nginx loads {len(files)} config file(s)")

def strip_existing():
    touched = []
    for p in files:
        try: t = open(p, encoding="utf-8", errors="replace").read()
        except OSError: continue
        if MARK in t:
            shutil.copy2(p, f"{p}.iridium-{time.strftime('%Y%m%d%H%M%S')}.bak")
            # sub with "" — BLOCK carries its own leading and trailing newline,
            # so consuming them restores the file byte-for-byte.
            open(p, "w", encoding="utf-8").write(BLOCK_RE.sub("", t))
            touched.append(p)
    return touched

if REMOVE:
    t = strip_existing()
    print("  removed from: " + (", ".join(t) if t else "(nothing found)"))
    if t:
        chk = sh("nginx", "-t")
        print("  nginx -t:", "ok" if chk.returncode == 0 else chk.stderr)
        sh("nginx", "-s", "reload")
    sys.exit(0)

if MARK in dump and not FORCE:
    print(f"  ! already mounted somewhere. If it is not working it is in the")
    print(f"    wrong server block — re-run with:  --force {DOMAIN or '<your-domain>'}")
    sys.exit(0)

# ---- find candidate server blocks ----------------------------------------
def server_blocks(text):
    for m in re.finditer(r"\bserver\s*\{", text):
        depth, i = 1, m.end()
        while i < len(text) and depth:
            if text[i] == "{": depth += 1
            elif text[i] == "}": depth -= 1
            i += 1
        if depth == 0:
            yield m.end(), text[m.end():i - 1]

cands = []
for path in files:
    try: text = open(path, encoding="utf-8", errors="replace").read()
    except OSError: continue
    for start, body in server_blocks(text):
        listens = re.findall(r"^\s*listen\s+([^;]+);", body, re.M)
        if not any(re.search(r"(^|[:\] ])80(\s|$)", l) and "443" not in l for l in listens):
            continue
        names = " ".join(re.findall(r"^\s*server_name\s+([^;]+);", body, re.M)).strip()
        if   DOMAIN and DOMAIN in names.split():      score = 4
        elif DOMAIN and DOMAIN in names:              score = 3
        elif any("default_server" in l for l in listens): score = 2
        elif names in ("", "_"):                      score = 1
        else:                                         score = 0
        cands.append((score, path, start, names or "(none)"))

if not cands:
    print("  ✗ no server block listening on port 80 found in the loaded config.")
    sys.exit(1)

cands.sort(key=lambda c: -c[0])
print("  port-80 server blocks found:")
for s, p, _, n in cands:
    print(f"      score {s}  {p}   server_name: {n}")
score, path, at, names = cands[0]
print(f"  -> chosen: {path}  (server_name: {names})")
if DOMAIN and score < 3:
    print(f"  ! nothing matched server_name '{DOMAIN}'; using the best available")

if DRY:
    print("\n  --dry-run: would insert the location block here. Nothing changed.")
    sys.exit(0)

if FORCE:
    strip_existing()
    files, dump = loaded_files()
    text = open(path, encoding="utf-8", errors="replace").read()
    # offsets moved after stripping; re-locate the same block
    for start, body in server_blocks(text):
        n2 = " ".join(re.findall(r"^\s*server_name\s+([^;]+);", body, re.M)).strip() or "(none)"
        ls = re.findall(r"^\s*listen\s+([^;]+);", body, re.M)
        if n2 == names and any(re.search(r"(^|[:\] ])80(\s|$)", l) and "443" not in l for l in ls):
            at = start; break

backup = f"{path}.iridium-{time.strftime('%Y%m%d%H%M%S')}.bak"
shutil.copy2(path, backup)
text = open(path, encoding="utf-8", errors="replace").read()
open(path, "w", encoding="utf-8").write(text[:at] + BLOCK + text[at:])
print(f"  backup: {backup}")

chk = sh("nginx", "-t")
if chk.returncode:
    shutil.copy2(backup, path)
    print("  ✗ nginx rejected the config — backup restored, nothing changed:")
    print(chk.stderr or chk.stdout); sys.exit(1)
print("  ✓ nginx -t passed")

if sh("nginx", "-s", "reload").returncode:
    sh("systemctl", "reload", "nginx")
print("  ✓ reloaded")

# ---- prove it, through nginx itself ---------------------------------------
host = DOMAIN or "localhost"
time.sleep(1)
r = sh("curl", "-s", "--max-time", "10", "-H", f"Host: {host}",
       f"http://127.0.0.1{PREFIX}/healthz")
body = (r.stdout or "").strip()
print()
if body == "ok":
    print(f"  PASS — http://{host}{PREFIX}/healthz returned 'ok' through nginx")
else:
    print(f"  FAIL — expected 'ok', got: {body[:200]!r}")
    print(f"         If this is a 404, the block is in a server that does not")
    print(f"         answer for '{host}'. Re-run:  --force <the right domain>")
    print(f"         If it is a 502, nginx matched but cannot reach {UPSTREAM} —")
    print(f"         check BIND_ADDR=127.0.0.1 in .env and that the container is up.")
PY
