#!/usr/bin/env bash
# Media stack control script.
#
#   ./stack.sh up       start everything, verify VPN, wait for services
#   ./stack.sh down     stop and remove containers (data is preserved)
#   ./stack.sh status    show what's running
#   ./stack.sh logs [svc] tail logs
#
# `up` refuses to leave qBittorrent running if torrent traffic is not
# actually behind the VPN.

set -euo pipefail

STACK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$STACK_DIR"

LOG_DIR="$STACK_DIR/logs"
mkdir -p "$LOG_DIR"
LOG_FILE="$LOG_DIR/stack-$(date +%Y%m%d-%H%M%S).log"

say()  { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
ok()   { printf '    \033[32mok\033[0m   %s\n' "$*"; }
warn() { printf '    \033[33mwarn\033[0m %s\n' "$*"; }
die()  { printf '    \033[31mFAIL\033[0m %s\n' "$*"; echo "log: $LOG_FILE"; exit 1; }

# Services that expose a web UI: name:port
WEB_SERVICES=(
  "jellyfin:8096"
  "jellyseerr:5055"
  "radarr:7878"
  "sonarr:8989"
  "prowlarr:9696"
  "qbittorrent:8080"
)

preflight() {
  say "Preflight"

  docker info >/dev/null 2>&1 || die "Docker isn't running. Start Docker Desktop first."
  ok "docker daemon up"

  [[ -f .env ]] || die ".env missing. gluetun needs OPENVPN_USER / OPENVPN_PASSWORD."
  # compose uses ${VAR:?} so this hard-fails rather than silently blanking creds
  docker compose config >/dev/null || die "compose config invalid (see above)"
  ok ".env present, compose config valid"

  # This stack is memory-hungry and this Mac has run out before. Warn, don't block.
  local swap_used swap_total
  swap_used=$(sysctl -n vm.swapusage | sed -n 's/.*used = \([0-9.]*\)M.*/\1/p')
  swap_total=$(sysctl -n vm.swapusage | sed -n 's/.*total = \([0-9.]*\)M.*/\1/p')
  if [[ -n "$swap_used" && -n "$swap_total" ]]; then
    local pct=$(( ${swap_used%.*} * 100 / ${swap_total%.*} ))
    if (( pct > 80 )); then
      warn "swap ${pct}% used (${swap_used}M/${swap_total}M) - the stack wants ~2.2GB"
      warn "if things feel slow, quit some apps or lower Docker's memory allocation"
    else
      ok "memory headroom fine (swap ${pct}% used)"
    fi
  fi
}

wait_healthy() {  # wait_healthy <container> <seconds>
  local name=$1 timeout=$2 waited=0 state
  while (( waited < timeout )); do
    state=$(docker inspect -f '{{.State.Health.Status}}' "$name" 2>/dev/null || echo "missing")
    [[ "$state" == "healthy" ]] && return 0
    sleep 3; waited=$((waited + 3))
  done
  return 1
}

verify_vpn() {
  say "Verifying VPN"

  wait_healthy gluetun 120 || die "gluetun never became healthy - check: docker logs gluetun"
  ok "gluetun healthy"

  local vpn_ip host_ip
  vpn_ip=$(docker exec gluetun wget -qO- -T 10 https://ipinfo.io/ip 2>/dev/null | tr -d '[:space:]' || true)
  host_ip=$(curl -s -m 10 https://ipinfo.io/ip 2>/dev/null | tr -d '[:space:]' || true)

  [[ -n "$vpn_ip" ]] || die "couldn't read VPN egress IP - assuming unsafe, stopping qbittorrent"

  if [[ -n "$host_ip" && "$vpn_ip" == "$host_ip" ]]; then
    docker compose stop qbittorrent >/dev/null 2>&1 || true
    die "LEAK: torrent egress ($vpn_ip) matches your real IP. qbittorrent stopped."
  fi

  ok "torrent egress $vpn_ip (real IP ${host_ip:-unknown}) - no leak"

  local fwd_port
  fwd_port=$(docker exec gluetun cat /tmp/gluetun/forwarded_port 2>/dev/null || true)
  [[ -n "$fwd_port" ]] && ok "port forwarding active: $fwd_port" || warn "no forwarded port yet (usually fine, it retries)"
}

wait_web() {
  say "Waiting for web UIs"
  local entry name port waited code
  for entry in "${WEB_SERVICES[@]}"; do
    name="${entry%%:*}"; port="${entry##*:}"
    waited=0
    while (( waited < 90 )); do
      # any HTTP response means it's listening; 401/302 are normal here
      code=$(curl -s -o /dev/null -w '%{http_code}' -m 5 "http://localhost:$port" 2>/dev/null || echo 000)
      [[ "$code" != "000" ]] && break
      sleep 3; waited=$((waited + 3))
    done
    if [[ "$code" == "000" ]]; then
      warn "$name not responding on :$port yet (it may still be starting)"
    else
      ok "$(printf '%-12s' "$name") :$port"
    fi
  done
}

summary() {
  say "Ready"
  cat <<EOF
    Jellyfin      http://localhost:8096    watch
    Jellyseerr    http://localhost:5055    request
    Radarr        http://localhost:7878    movies
    Sonarr        http://localhost:8989    tv
    Prowlarr      http://localhost:9696    indexers
    qBittorrent   http://localhost:8080    downloads

    log: $LOG_FILE
EOF
}

# Remote access is the one part of this stack that is reachable from the
# internet, so it gets its own gate. Everything here is a hard stop, not a
# warning - a half-configured public endpoint is worse than none.
remote_preflight() {
  say "Remote access preflight"

  # shellcheck disable=SC1091
  set -a; [[ -f .env ]] && . ./.env; set +a

  [[ -n "${DOMAIN_WATCH:-}"   ]] || die "DOMAIN_WATCH not set in .env"
  [[ -n "${DOMAIN_REQUEST:-}" ]] || die "DOMAIN_REQUEST not set in .env"
  [[ "$DOMAIN_WATCH" != *example.invalid ]] || die "DOMAIN_WATCH is still the placeholder"
  ok "domains: $DOMAIN_WATCH / $DOMAIN_REQUEST"

  [[ -n "${CROWDSEC_API_KEY:-}" && "$CROWDSEC_API_KEY" != "unset" ]] \
    || die "CROWDSEC_API_KEY not set - start crowdsec once, then: docker exec crowdsec cscli bouncers add caddy-bouncer"
  ok "crowdsec bouncer key present"

  # The blank-password admin account must not be the thing facing the internet.
  if [[ -f config/jellyfin/data/data/jellyfin.db ]]; then
    local nopw
    nopw=$(sqlite3 config/jellyfin/data/data/jellyfin.db \
      "select count(*) from Users where Password is null or Password='';" 2>/dev/null || echo "?")
    if [[ "$nopw" != "0" ]]; then
      die "Jellyfin has $nopw account(s) with NO password. Set one before exposing this."
    fi
    ok "no passwordless Jellyfin accounts"
  else
    warn "couldn't read Jellyfin user DB - verify passwords manually"
  fi

  # Jellyfin must resolve to THIS network (grey cloud). If it resolves to a
  # Cloudflare address, video would transit their CDN against their terms.
  local host_ip dns_ip
  host_ip=$(curl -s -m 10 https://ipinfo.io/ip 2>/dev/null | tr -d '[:space:]' || true)
  dns_ip=$(dig +short "$DOMAIN_WATCH" 2>/dev/null | tail -1 || true)
  if [[ -z "$dns_ip" ]]; then
    warn "$DOMAIN_WATCH does not resolve yet - DNS may still be propagating"
  elif [[ -n "$host_ip" && "$dns_ip" != "$host_ip" ]]; then
    warn "$DOMAIN_WATCH resolves to $dns_ip but your IP is $host_ip"
    warn "if that's a Cloudflare address, turn the orange cloud OFF for this record"
  else
    ok "$DOMAIN_WATCH -> $dns_ip (direct, grey cloud)"
  fi

  say "Reminder"
  echo "    Ports 80 and 443 must be forwarded from your router to this Mac."
  echo "    Your public IP is DHCP - consider a static reservation or DDNS."
}

main() {
  case "${1:-up}" in
    remote)
      case "${2:-}" in
        up)
          preflight
          remote_preflight
          say "Starting stack + remote access"
          docker compose --profile remote up -d --build
          verify_vpn
          wait_web
          say "Public endpoints"
          echo "    https://${DOMAIN_WATCH}    (Jellyfin)"
          echo "    https://${DOMAIN_REQUEST}  (Jellyseerr)"
          ;;
        down)
          say "Stopping remote access only (media stack stays up)"
          docker compose --profile remote stop caddy crowdsec
          docker compose --profile remote rm -f caddy crowdsec
          ok "public endpoints closed"
          ;;
        *)
          echo "usage: ./stack.sh remote [up|down]"
          return 1
          ;;
      esac
      ;;
    up)
      preflight
      say "Starting containers"
      docker compose up -d
      verify_vpn
      wait_web
      summary
      ;;
    down)
      say "Stopping stack"
      docker compose down
      ok "containers removed - config, media and downloads untouched"
      ;;
    status)
      say "Containers"
      docker compose ps
      if docker inspect gluetun >/dev/null 2>&1; then
        say "VPN"
        docker exec gluetun wget -qO- -T 8 https://ipinfo.io/json 2>/dev/null | head -5 || warn "gluetun not answering"
      fi
      ;;
    logs)
      shift
      docker compose logs -f --tail=100 "$@"
      ;;
    *)
      echo "usage: ./stack.sh [up|down|status|logs [service]]"
      return 1
      ;;
  esac
}

# `logs` is an interactive tail - don't capture it, just stream to the terminal.
# Everything else is piped through tee, so the log file is always complete
# before the script exits (pipefail preserves main's exit code).
if [[ "${1:-up}" == "logs" ]]; then
  main "$@"
else
  main "$@" 2>&1 | tee -a "$LOG_FILE"
fi
