#!/usr/bin/env bash
#
# Mount this app under an nginx that runs IN A CONTAINER and owns the public
# port 80/443.
#
#   sudo ./scripts/nginx-container-mount.sh example.com
#   sudo ./scripts/nginx-container-mount.sh --dry-run example.com
#   sudo ./scripts/nginx-container-mount.sh --force example.com   # re-target
#   sudo ./scripts/nginx-container-mount.sh --remove
#
# Why this exists: a host can run one nginx bound to 127.0.0.1 and a different
# nginx in a container bound to 0.0.0.0. Editing the host one then works
# perfectly on the host and does nothing for the internet. This targets the
# container that actually publishes the port.
#
# Two things differ from the host case:
#   * the upstream is iridium-web:8899, the CONTAINER port, over a shared
#     Docker network — a container cannot reach the host's 127.0.0.1:8890;
#   * if nginx's config is not bind-mounted, edits live inside the container
#     and are lost when it is recreated. The script says so loudly.

set -euo pipefail

PREFIX=${IRIDIUM_PREFIX:-/iridium}
APP=${IRIDIUM_APP:-iridium-web}
APP_PORT=${IRIDIUM_APP_PORT:-8899}
NET=${IRIDIUM_NET:-iridium_net}
DOMAIN=""; DRY=0; FORCE=0; REMOVE=0; NGX=""
for a in "$@"; do
  case "$a" in
    --dry-run) DRY=1 ;;
    --force)   FORCE=1 ;;
    --remove)  REMOVE=1 ;;
    --container=*) NGX="${a#*=}" ;;
    -*) echo "unknown option: $a"; exit 2 ;;
    *) DOMAIN="$a" ;;
  esac
done
[ "$(id -u)" -eq 0 ] || { echo "run with sudo"; exit 1; }
command -v docker >/dev/null || { echo "docker not found"; exit 1; }

MARK="Iridium ground station (managed)"

# ---- 1. which container publishes port 80? ---------------------------------
if [ -z "$NGX" ]; then
  NGX=$(docker ps --format '{{.Names}}\t{{.Ports}}' \
        | grep -E '0\.0\.0\.0:80->|:::80->' | head -1 | cut -f1 || true)
fi
[ -z "$NGX" ] && { echo "✗ no container publishes 0.0.0.0:80."; \
                   docker ps --format '  {{.Names}}  {{.Ports}}'; exit 1; }
echo "  public :80 container : $NGX"

docker exec "$NGX" sh -c 'command -v nginx' >/dev/null 2>&1 \
  || { echo "✗ '$NGX' does not contain nginx — is it Caddy/Traefik? Use the"; \
       echo "  label or Caddyfile route instead."; exit 1; }

# ---- 2. make sure it can reach the app ------------------------------------
docker ps --format '{{.Names}}' | grep -qx "$APP" \
  || { echo "✗ container '$APP' is not running"; exit 1; }

APP_NETS=$(docker inspect "$APP" --format '{{range $k,$v := .NetworkSettings.Networks}}{{$k}} {{end}}')
NGX_NETS=$(docker inspect "$NGX" --format '{{range $k,$v := .NetworkSettings.Networks}}{{$k}} {{end}}')
SHARED=""
for a in $APP_NETS; do for b in $NGX_NETS; do [ "$a" = "$b" ] && SHARED=$a; done; done
if [ -z "$SHARED" ]; then
  TARGET=$(echo "$NGX_NETS" | awk '{print $1}')
  docker network connect "$TARGET" "$APP" 2>/dev/null || docker network connect "$NET" "$NGX"
  SHARED=$TARGET
  echo "  joined network        : $SHARED"
else
  echo "  shared network        : $SHARED"
fi

if docker exec "$NGX" sh -c "wget -q -O- --timeout=5 http://$APP:$APP_PORT/healthz 2>/dev/null \
     || curl -fsS --max-time 5 http://$APP:$APP_PORT/healthz 2>/dev/null" | grep -qx ok; then
  echo "  upstream reachable    : http://$APP:$APP_PORT/healthz -> ok"
else
  echo "  ! could not verify the upstream from inside $NGX (it may lack wget/curl)."
  echo "    Continuing — nginx itself does not need those tools."
fi

# ---- 3. locate the config file that owns the :80 server block --------------
# Which CONTAINER port is published as host :80? It is not necessarily 80.
# A container published as 0.0.0.0:80->8080/tcp serves the internet from its
# `listen 8080` block, so editing `listen 80` — and self-testing against
# 127.0.0.1:80 — succeeds locally and is invisible from outside.
CPORT=$(docker inspect "$NGX" --format '{{json .NetworkSettings.Ports}}' \
  | python3 -c "
import json,sys
try: d=json.load(sys.stdin) or {}
except Exception: d={}
for cp,binds in d.items():
    for b in (binds or []):
        if str(b.get('HostPort'))=='80':
            print(cp.split('/')[0]); sys.exit()
" 2>/dev/null)
[ -z "$CPORT" ] && CPORT=80
echo "  host :80 maps to container port : $CPORT"

# Track the current file from nginx -T's markers, print the one that first
# declares a listener on THAT port. Uses sub() rather than a substr() offset —
# counting the prefix by hand silently truncates the path.
CONF=$(docker exec "$NGX" nginx -T 2>/dev/null | awk -v p="$CPORT" '
  /^# configuration file /{f=$0; sub(/^# configuration file /,"",f); sub(/:$/,"",f)}
  $0 ~ ("listen[ \t]+(\\[::\\]:)?" p "([ \t;]|$)"){if(f!=""){print f; exit}}')
[ -z "$CONF" ] && { echo "✗ no port-80 server block found inside $NGX"; exit 1; }
echo "  config inside container: $CONF"

# Is it bind-mounted? Then edit on the host so it survives a recreate.
HOSTCONF=$(docker inspect "$NGX" --format \
  "{{range .Mounts}}{{if eq .Destination \"$CONF\"}}{{.Source}}{{end}}{{end}}")
if [ -z "$HOSTCONF" ]; then
  MDIR=$(docker inspect "$NGX" --format '{{range .Mounts}}{{.Destination}}|{{.Source}}
{{end}}' | grep -F "$(dirname "$CONF")|" | head -1 || true)
  [ -n "$MDIR" ] && HOSTCONF="${MDIR#*|}/$(basename "$CONF")"
fi
if [ -n "$HOSTCONF" ] && [ -f "$HOSTCONF" ]; then
  echo "  bind-mounted from host : $HOSTCONF  (edits persist)"
else
  echo "  ! NOT bind-mounted — edits live inside the container and are LOST"
  echo "    if it is recreated. Persist them in the image or a mount afterwards."
fi

BLOCK=$(cat <<EOF

    # --- $MARK ---
    location = $PREFIX { return 301 $PREFIX/; }
    location $PREFIX/ {
        proxy_pass http://$APP:$APP_PORT/;
        proxy_http_version 1.1;
        proxy_set_header Host               \$host;
        proxy_set_header X-Real-IP          \$remote_addr;
        proxy_set_header X-Forwarded-For    \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto  \$scheme;
        proxy_set_header X-Forwarded-Prefix $PREFIX;
        proxy_read_timeout 60s;
        proxy_buffering off;
    }
    # --- end $MARK ---
EOF
)

if [ "$DRY" = 1 ]; then
  echo; echo "  --dry-run: would insert into $CONF:"; echo "$BLOCK"; exit 0
fi

# ---- 4. edit (host file if possible, else inside the container) -----------
# Pull the file out, edit it properly on the host with python, push it back.
# `docker cp` writes through a bind mount, so this one path covers both the
# mounted and unmounted cases, and gives real server-block selection instead of
# "first server { in the file" — which is how a mount lands in a block that
# never answers for the site.
command -v python3 >/dev/null || { echo "✗ python3 required on the host"; exit 1; }
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
docker cp "$NGX:$CONF" "$TMP/conf" >/dev/null
cp "$TMP/conf" "$TMP/conf.orig"

BLOCK="$BLOCK" MARK="$MARK" DOMAIN="$DOMAIN" CPORT="$CPORT" \
REMOVE="$REMOVE" FORCE="$FORCE" python3 - "$TMP/conf" <<'PY'
import os, re, sys
path=sys.argv[1]
BLOCK=os.environ["BLOCK"]; MARK=os.environ["MARK"]; DOMAIN=os.environ["DOMAIN"]
CPORT=os.environ["CPORT"]; REMOVE=os.environ["REMOVE"]=="1"; FORCE=os.environ["FORCE"]=="1"
t=open(path,encoding="utf-8",errors="replace").read()
rx=re.compile(r"\n?[ \t]*# --- "+re.escape(MARK)+r" ---.*?# --- end "+re.escape(MARK)+r" ---\n?",re.S)
if REMOVE or FORCE:
    t=rx.sub("",t)
if REMOVE:
    open(path,"w",encoding="utf-8").write(t); print("  removed"); sys.exit(0)
if MARK in t:
    print("  already present (use --force to re-target)"); sys.exit(0)

def blocks(text):
    for m in re.finditer(r"\bserver\s*\{", text):
        d,i=1,m.end()
        while i<len(text) and d:
            if text[i]=="{": d+=1
            elif text[i]=="}": d-=1
            i+=1
        if d==0: yield m.end(), text[m.end():i-1]

cands=[]
for start,body in blocks(t):
    ls=re.findall(r"^\s*listen\s+([^;]+);", body, re.M)
    if not any(re.search(r"(^|[:\] ])"+re.escape(CPORT)+r"(\s|$)", l) for l in ls):
        continue
    names=" ".join(re.findall(r"^\s*server_name\s+([^;]+);", body, re.M)).strip()
    if   DOMAIN and DOMAIN in names.split():          s=4
    elif DOMAIN and DOMAIN in names:                  s=3
    elif any("default_server" in l for l in ls):      s=2
    elif names in ("","_"):                           s=1
    else:                                             s=0
    cands.append((s,start,names or "(none)"))
if not cands:
    print(f"  ✗ no server block listening on {CPORT} in this file"); sys.exit(1)
cands.sort(key=lambda c:-c[0])
for s,_,n in cands: print(f"      score {s}  server_name: {n}")
s,at,names=cands[0]
print(f"  -> inserting into the block with server_name: {names}")
open(path,"w",encoding="utf-8").write(t[:at]+BLOCK+"\n"+t[at:])
PY
rc=$?
[ $rc -ne 0 ] && exit $rc
docker cp "$TMP/conf" "$NGX:$CONF" >/dev/null
docker cp "$TMP/conf.orig" "$NGX:$CONF.iridium.bak" >/dev/null 2>&1 || true

# ---- 5. validate, reload, prove ------------------------------------------
if ! docker exec "$NGX" nginx -t >/dev/null 2>&1; then
  echo "  ✗ nginx rejected the config — restoring"
  docker cp "$TMP/conf.orig" "$NGX:$CONF" >/dev/null
  docker exec "$NGX" nginx -t || true
  exit 1
fi
echo "  ✓ nginx -t passed"
docker exec "$NGX" nginx -s reload >/dev/null 2>&1 || docker restart "$NGX" >/dev/null
echo "  ✓ reloaded"
[ "$REMOVE" = 1 ] && exit 0

sleep 1
HOST_HDR=${DOMAIN:-localhost}
# Test the port the internet actually lands on, not port 80 by habit.
OUT=$(docker exec "$NGX" sh -c \
  "wget -q -O- --timeout=8 --header='Host: $HOST_HDR' http://127.0.0.1:$CPORT$PREFIX/healthz 2>/dev/null \
   || curl -s --max-time 8 -H 'Host: $HOST_HDR' http://127.0.0.1:$CPORT$PREFIX/healthz 2>/dev/null" || true)
echo
if [ "$(echo "$OUT" | tr -d '[:space:]')" = "ok" ]; then
  echo "  PASS — http://$HOST_HDR$PREFIX/healthz returns 'ok' through the public nginx"
  echo "         Try it from outside:  curl -s http://$HOST_HDR$PREFIX/healthz"
else
  echo "  FAIL — expected 'ok', got: $(echo "$OUT" | head -c 200)"
  echo "         404 -> wrong server block; re-run with --force <the right domain>"
  echo "         502 -> nginx matched but cannot reach $APP:$APP_PORT (network)"
fi
