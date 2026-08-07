#!/usr/bin/env bash
#
# Mount this app under an existing nginx site, without you having to work out
# which server block is the right one.
#
#   sudo ./scripts/nginx-mount.sh                    # auto-detect
#   sudo ./scripts/nginx-mount.sh example.com        # pin the server_name
#   sudo ./scripts/nginx-mount.sh --dry-run          # show, change nothing
#
# It picks the server block that listens on 80 (a block listening only on 443
# is useless if something else already owns 443 on this host), backs the file
# up, inserts the location, validates with `nginx -t`, and restores the backup
# if validation fails. Nothing is reloaded unless the config is valid.

set -euo pipefail

PREFIX=${IRIDIUM_PREFIX:-/iridium}
UPSTREAM=${IRIDIUM_UPSTREAM:-127.0.0.1:8890}
DOMAIN=""
DRY=0
for a in "$@"; do
  case "$a" in
    --dry-run) DRY=1 ;;
    -*) echo "unknown option: $a"; exit 2 ;;
    *) DOMAIN="$a" ;;
  esac
done

command -v nginx >/dev/null || { echo "nginx not found on this host"; exit 1; }
command -v python3 >/dev/null || { echo "python3 required"; exit 1; }
[ "$(id -u)" -eq 0 ] || { echo "run with sudo"; exit 1; }

PREFIX="$PREFIX" UPSTREAM="$UPSTREAM" DOMAIN="$DOMAIN" DRY="$DRY" python3 <<'PY'
import os, re, shutil, subprocess, sys, time

PREFIX   = os.environ["PREFIX"].rstrip("/")
UPSTREAM = os.environ["UPSTREAM"]
DOMAIN   = os.environ["DOMAIN"]
DRY      = os.environ["DRY"] == "1"
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

def die(msg, code=1):
    print(f"  ✗ {msg}")
    sys.exit(code)

# ---- which files does nginx actually load? --------------------------------
try:
    dump = subprocess.run(["nginx", "-T"], capture_output=True, text=True,
                          check=True).stdout
except subprocess.CalledProcessError as e:
    die("`nginx -T` failed — the running config is already invalid:\n" + (e.stderr or ""))

files = re.findall(r"^# configuration file (.+?):$", dump, re.M)
files = list(dict.fromkeys(files))
print(f"  nginx loads {len(files)} config file(s)")

if MARK in dump:
    print(f"  ✓ already mounted at {PREFIX}/ — nothing to do")
    sys.exit(0)

# ---- find server blocks, by brace depth, in the real files ----------------
def server_blocks(text):
    """Yield (start_of_body, end, body) for each top-level `server { ... }`."""
    for m in re.finditer(r"\bserver\s*\{", text):
        depth, i = 1, m.end()
        while i < len(text) and depth:
            if text[i] == "{": depth += 1
            elif text[i] == "}": depth -= 1
            i += 1
        if depth == 0:
            yield m.end(), i - 1, text[m.end():i - 1]

candidates = []
for path in files:
    try:
        text = open(path, encoding="utf-8", errors="replace").read()
    except OSError:
        continue
    for start, end, body in server_blocks(text):
        # Ignore nested blocks' own listens by only looking at this body.
        listens = re.findall(r"^\s*listen\s+([^;]+);", body, re.M)
        if not any(re.search(r"(^|[: ])80(\s|$)", l) and "443" not in l for l in listens):
            continue
        names = " ".join(re.findall(r"^\s*server_name\s+([^;]+);", body, re.M))
        score = 0
        if DOMAIN and DOMAIN in names: score = 3
        elif any("default_server" in l for l in listens): score = 2
        elif names.strip() in ("", "_"): score = 1
        candidates.append((score, path, start, names.strip() or "(none)"))

if not candidates:
    die("no server block listening on port 80 was found.\n"
        "    A block listening only on 443 will not help if another service owns 443.")

candidates.sort(key=lambda c: -c[0])
score, path, insert_at, names = candidates[0]
print(f"  target: {path}")
print(f"          server_name: {names}")
if len(candidates) > 1:
    print(f"          ({len(candidates)} port-80 blocks found; picked the best match)")
if DOMAIN and score < 3:
    print(f"  ! no port-80 block matched server_name '{DOMAIN}'; using the above")

if DRY:
    print("\n  --dry-run: would insert\n" + BLOCK)
    sys.exit(0)

# ---- edit, validate, roll back on failure ---------------------------------
backup = f"{path}.iridium-{time.strftime('%Y%m%d%H%M%S')}.bak"
shutil.copy2(path, backup)
print(f"  backup: {backup}")

text = open(path, encoding="utf-8", errors="replace").read()
open(path, "w", encoding="utf-8").write(text[:insert_at] + BLOCK + text[insert_at:])

check = subprocess.run(["nginx", "-t"], capture_output=True, text=True)
if check.returncode != 0:
    shutil.copy2(backup, path)
    die("nginx rejected the config — restored the backup, nothing changed:\n"
        + (check.stderr or check.stdout))

print("  ✓ nginx -t passed")
reload = subprocess.run(["nginx", "-s", "reload"], capture_output=True, text=True)
if reload.returncode != 0:
    subprocess.run(["systemctl", "reload", "nginx"], check=False)
print("  ✓ reloaded")
print(f"\n  Try:  curl -s http://<this-host>{PREFIX}/healthz     # expect: ok")
PY
