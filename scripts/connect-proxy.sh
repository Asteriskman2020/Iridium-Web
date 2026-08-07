#!/usr/bin/env bash
#
# Connect a containerised reverse proxy (Caddy, nginx, Traefik...) to this
# stack's network, then print the exact config block to add.
#
#   sudo ./scripts/connect-proxy.sh              # detect + connect + show config
#   sudo ./scripts/connect-proxy.sh caddy-1      # if auto-detection picks wrong
#
# It only ever runs `docker network connect`, which is additive and reversible
# (`docker network disconnect iridium_net <container>`). It does NOT edit your
# proxy config — that stays your call, because a bad edit takes your other
# sites down with it.

set -euo pipefail

NET=iridium_net
APP=iridium-web
APP_PORT=8899
PREFIX=/iridium

red()  { printf '\033[31m%s\033[0m\n' "$*"; }
grn()  { printf '\033[32m%s\033[0m\n' "$*"; }
bold() { printf '\033[1m%s\033[0m\n' "$*"; }

command -v docker >/dev/null || { red "docker not found"; exit 1; }

# ---- 1. the app must be up -------------------------------------------------
if ! docker ps --format '{{.Names}}' | grep -qx "$APP"; then
  red "Container '$APP' is not running."
  echo "Start it first:   cd \"\$(dirname \"\$0\")/..\" && docker compose up -d --build"
  exit 1
fi

if ! docker network inspect "$NET" >/dev/null 2>&1; then
  red "Network '$NET' does not exist."
  echo "Re-create the stack so it is defined:   docker compose up -d"
  exit 1
fi
grn "✓ $APP is running and network $NET exists"

# ---- 2. find the proxy -----------------------------------------------------
if [ $# -ge 1 ]; then
  PROXY=$1
else
  # Anything publishing 443, or an image that looks like a proxy.
  PROXY=$(docker ps --format '{{.Names}}\t{{.Image}}\t{{.Ports}}' \
          | grep -iE 'caddy|traefik|nginx-proxy|swag|npm|nginx' \
          | grep -viE "^${APP}\b" \
          | head -1 | cut -f1 || true)
  [ -z "$PROXY" ] && PROXY=$(docker ps --format '{{.Names}}\t{{.Ports}}' \
          | grep ':443->' | head -1 | cut -f1 || true)
fi

if [ -z "${PROXY:-}" ]; then
  red "Could not identify the reverse-proxy container."
  echo "Running containers:"
  docker ps --format '  {{.Names}}\t{{.Image}}\t{{.Ports}}'
  echo
  echo "Re-run with the name:   sudo $0 <container-name>"
  exit 1
fi
grn "✓ reverse proxy looks like: $PROXY"

# ---- 3. attach it ----------------------------------------------------------
if docker inspect "$PROXY" --format '{{range $k,$v := .NetworkSettings.Networks}}{{$k}} {{end}}' \
     | tr ' ' '\n' | grep -qx "$NET"; then
  grn "✓ $PROXY is already on $NET"
else
  docker network connect "$NET" "$PROXY"
  grn "✓ connected $PROXY to $NET"
fi

# ---- 4. prove the proxy can actually reach the app -------------------------
echo
bold "Checking that $PROXY can reach $APP…"
if docker exec "$PROXY" sh -c \
     "wget -q -O- --timeout=5 http://$APP:$APP_PORT/healthz 2>/dev/null \
      || curl -fsS --max-time 5 http://$APP:$APP_PORT/healthz 2>/dev/null" \
     2>/dev/null | grep -qx ok; then
  grn "✓ reachable: http://$APP:$APP_PORT/healthz returned ok"
else
  red "✗ could not verify from inside $PROXY"
  echo "  (the container may lack wget and curl — not fatal, the proxy itself"
  echo "   does not need them. Continue and test through the browser.)"
fi

# ---- 5. print the config to add -------------------------------------------
CADDYFILE=$(docker inspect "$PROXY" --format \
  '{{range .Mounts}}{{if eq .Destination "/etc/caddy/Caddyfile"}}{{.Source}}{{end}}{{end}}' 2>/dev/null || true)

cat <<EOF

$(bold "─── Add this to your proxy config ───")

Caddy — inside the site block for your domain, ABOVE any catch-all:

    handle_path ${PREFIX}/* {
        reverse_proxy ${APP}:${APP_PORT} {
            header_up X-Forwarded-Prefix ${PREFIX}
        }
    }

EOF

if [ -n "$CADDYFILE" ]; then
  echo "Your Caddyfile is bind-mounted from:"
  bold "    $CADDYFILE"
  echo
  echo "Then:"
  echo "    docker exec $PROXY caddy validate --config /etc/caddy/Caddyfile"
  echo "    docker exec $PROXY caddy reload   --config /etc/caddy/Caddyfile"
else
  echo "Could not find a bind-mounted Caddyfile; check:"
  echo "    docker inspect $PROXY --format '{{json .Mounts}}'"
  echo "After editing, reload with:  docker exec $PROXY caddy reload --config /etc/caddy/Caddyfile"
fi

cat <<EOF

$(bold "handle_path strips ${PREFIX} before forwarding") — that is what makes the
app's routes line up. X-Forwarded-Prefix hands the prefix back so it generates
${PREFIX}/login rather than /login. Caddy sets X-Forwarded-Proto/For/Host itself.

Then check from anywhere:
    curl -s https://<your-domain>${PREFIX}/healthz     # expect: ok
EOF
