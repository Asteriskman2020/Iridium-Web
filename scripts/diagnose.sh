#!/usr/bin/env bash
# One-shot report covering every layer between the internet and this app.
#   sudo ./scripts/diagnose.sh [domain] [prefix]
# Paste the whole output — it is ~25 lines and contains no secrets.
set -uo pipefail
DOMAIN=${1:-}
PREFIX=${2:-/iridium}
APP=iridium-web

line() { printf '%s\n' "----------------------------------------------------------"; }

line; echo "1. APP CONTAINER"
docker ps --format '{{.Names}}\t{{.Status}}\t{{.Ports}}' | grep -E "^$APP\b" || echo "  NOT RUNNING"
echo -n "  local healthz (container port) : "
docker exec "$APP" sh -c 'wget -qO- --timeout=4 http://127.0.0.1:8899/healthz 2>/dev/null || echo FAIL' 2>/dev/null || echo "exec failed"
echo "  routing env:"
docker inspect "$APP" --format '{{range .Config.Env}}{{println .}}{{end}}' 2>/dev/null \
  | grep -iE '^(VIRTUAL_|URL_PREFIX|BEHIND_TLS|BIND_ADDR)' | sed 's/^/      /' || echo "      (none)"
echo "  networks:"
docker inspect "$APP" --format '{{range $k,$v := .NetworkSettings.Networks}}      {{$k}}  ip={{$v.IPAddress}}{{println}}{{end}}' 2>/dev/null

line; echo "2. WHAT OWNS THE PUBLIC PORTS"
ss -ltnp 2>/dev/null | grep -E ':(80|443)\s' | sed 's/^/  /' || netstat -ltnp 2>/dev/null | grep -E ':(80|443)\b' | sed 's/^/  /'
echo "  containers publishing 80/443:"
docker ps --format '{{.Names}}\t{{.Image}}\t{{.Ports}}' | grep -E ':80->|:443->' | sed 's/^/      /'

line; echo "3. nginx-proxy (routes by env vars, regenerates its own config)"
NP=$(docker ps --format '{{.Names}}\t{{.Image}}' | grep -i 'nginx-proxy' | head -1 | cut -f1)
if [ -n "$NP" ]; then
  echo "  container : $NP"
  echo "  image     : $(docker inspect "$NP" --format '{{.Config.Image}}')"
  echo "  networks  : $(docker inspect "$NP" --format '{{range $k,$v := .NetworkSettings.Networks}}{{$k}} {{end}}')"
  echo -n "  our route present in generated config : "
  docker exec "$NP" sh -c 'grep -c iridium /etc/nginx/conf.d/default.conf 2>/dev/null || echo 0'
  echo "  matching config lines:"
  docker exec "$NP" sh -c 'grep -n -B2 -A6 iridium /etc/nginx/conf.d/default.conf 2>/dev/null | head -40' | sed 's/^/      /'
  echo "  recent log:"
  docker logs "$NP" --tail 12 2>&1 | sed 's/^/      /'
else
  echo "  no nginx-proxy container found"
fi

line; echo "4. REACHABILITY FROM THE PROXY"
if [ -n "$NP" ]; then
  echo -n "  $NP -> http://$APP:8899/healthz : "
  docker exec "$NP" sh -c "wget -qO- --timeout=4 http://$APP:8899/healthz 2>/dev/null || echo UNREACHABLE"
fi

line; echo "5. FROM THE HOST, THROUGH THE PUBLIC PORT"
for h in "${DOMAIN:-localhost}" 127.0.0.1; do
  printf '  Host:%-18s %s%s/healthz -> %s\n' "$h" "http://127.0.0.1" "$PREFIX" \
    "$(curl -s -o /dev/null -w '%{http_code}' --max-time 8 -H "Host: $h" "http://127.0.0.1$PREFIX/healthz")"
done
printf '  root for comparison            -> %s\n' \
  "$(curl -s -o /dev/null -w '%{http_code}' --max-time 8 -H "Host: ${DOMAIN:-localhost}" http://127.0.0.1/)"
line
