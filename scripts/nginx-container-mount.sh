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
# Track the current file from nginx -T's markers, print the one that first
# declares a port-80 listener. Uses sub() rather than a substr() offset —
# counting the prefix by hand silently truncates the path.
CONF=$(docker exec "$NGX" nginx -T 2>/dev/null | awk '
  /^# configuration file /{f=$0; sub(/^# configuration file /,"",f); sub(/:$/,"",f)}
  /listen[ \t]+(\[::\]:)?80([ \t;]|$)/{if(f!=""){print f; exit}}')
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
py_edit() {  # $1 = file path on host
  BLOCK="$BLOCK" MARK="$MARK" DOMAIN="$DOMAIN" REMOVE="$REMOVE" FORCE="$FORCE" \
  python3 - "$1" <<'PY'
import os, re, shutil, sys, time
path=sys.argv[1]; BLOCK=os.environ["BLOCK"]; MARK=os.environ["MARK"]
REMOVE=os.environ["REMOVE"]=="1"; FORCE=os.environ["FORCE"]=="1"
t=open(path,encoding="utf-8",errors="replace").read()
rx=re.compile(r"\n?[ \t]*# --- "+re.escape(MARK)+r" ---.*?# --- end "+re.escape(MARK)+r" ---\n?",re.S)
shutil.copy2(path,f"{path}.iridium-{time.strftime('%Y%m%d%H%M%S')}.bak")
if REMOVE or FORCE: t=rx.sub("",t)
if REMOVE:
    open(path,"w",encoding="utf-8").write(t); print("  removed"); sys.exit(0)
if MARK in t: print("  already present"); sys.exit(0)
m=re.search(r"\bserver\s*\{",t)
if not m: print("  ✗ no server block"); sys.exit(1)
open(path,"w",encoding="utf-8").write(t[:m.end()]+BLOCK+"\n"+t[m.end():])
print("  inserted")
PY
}

if [ -n "$HOSTCONF" ] && [ -f "$HOSTCONF" ]; then
  command -v python3 >/dev/null || { echo "✗ python3 required on the host"; exit 1; }
  py_edit "$HOSTCONF"
else
  docker exec "$NGX" cp "$CONF" "$CONF.bak"
  if [ "$REMOVE" = 1 ] || [ "$FORCE" = 1 ]; then
    docker exec "$NGX" sh -c "sed -i '/# --- $MARK ---/,/# --- end $MARK ---/d' '$CONF'"
  fi
  [ "$REMOVE" = 1 ] || docker exec -i "$NGX" sh -c \
    "awk -v b=\"\$(cat)\" 'NR==1{p=0} /server[ \t]*\{/&&!p{print;print b;p=1;next}{print}' '$CONF' > /tmp/n && cp /tmp/n '$CONF'" <<<"$BLOCK"
fi

# ---- 5. validate, reload, prove ------------------------------------------
if ! docker exec "$NGX" nginx -t >/dev/null 2>&1; then
  echo "  ✗ nginx rejected the config — restoring"
  if [ -n "$HOSTCONF" ] && [ -f "$HOSTCONF" ]; then
    cp "$(ls -t "$HOSTCONF".iridium-*.bak | head -1)" "$HOSTCONF"
  else
    docker exec "$NGX" cp "$CONF.bak" "$CONF"
  fi
  docker exec "$NGX" nginx -t || true
  exit 1
fi
echo "  ✓ nginx -t passed"
docker exec "$NGX" nginx -s reload >/dev/null 2>&1 || docker restart "$NGX" >/dev/null
echo "  ✓ reloaded"
[ "$REMOVE" = 1 ] && exit 0

sleep 1
HOST_HDR=${DOMAIN:-localhost}
OUT=$(docker exec "$NGX" sh -c \
  "wget -q -O- --timeout=8 --header='Host: $HOST_HDR' http://127.0.0.1$PREFIX/healthz 2>/dev/null \
   || curl -s --max-time 8 -H 'Host: $HOST_HDR' http://127.0.0.1$PREFIX/healthz 2>/dev/null" || true)
echo
if [ "$(echo "$OUT" | tr -d '[:space:]')" = "ok" ]; then
  echo "  PASS — http://$HOST_HDR$PREFIX/healthz returns 'ok' through the public nginx"
  echo "         Try it from outside:  curl -s http://$HOST_HDR$PREFIX/healthz"
else
  echo "  FAIL — expected 'ok', got: $(echo "$OUT" | head -c 200)"
  echo "         404 -> wrong server block; re-run with --force <the right domain>"
  echo "         502 -> nginx matched but cannot reach $APP:$APP_PORT (network)"
fi
