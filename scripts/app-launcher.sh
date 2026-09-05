#!/usr/bin/env bash
# macOS ONLY - backing script for the double-clickable .app bundles in
# ~/Applications (osascript dialogs, Docker Desktop). On the Ubuntu server the
# equivalent is systemd/media-stack.service; see docs/UBUNTU-SERVER.md.
#
#   app-launcher.sh watch    start Jellyfin only, open it in the browser
#   app-launcher.sh full     start the whole stack (VPN + downloaders), open Jellyseerr
#   app-launcher.sh stop     stop everything
#
# Launched from Finder, so it must not assume a login shell:
#   - PATH is set explicitly (Finder gives /usr/bin:/bin:/usr/sbin:/sbin, which
#     has no docker), and
#   - there's no terminal to print to, so progress goes to notifications and a log.

set -uo pipefail

# /usr/local/bin holds the docker symlink; homebrew paths for everything else.
export PATH="/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"

STACK_DIR="$HOME/media-stack"
cd "$STACK_DIR" || exit 1

LOG_DIR="$STACK_DIR/logs"
mkdir -p "$LOG_DIR"
LOG_FILE="$LOG_DIR/app-launcher-$(date +%Y%m%d-%H%M%S).log"
exec 2>>"$LOG_FILE"

log() { printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*" >>"$LOG_FILE"; }

# Banner notifications are unreliable here: these bundles are unsigned and
# ad-hoc, so Notification Center often drops them silently - which made the
# Stop app look broken when it was working fine. A dialog always renders.
# `giving up after` auto-dismisses so nothing is left sitting on screen.
notify() {
  osascript -e "display notification \"$2\" with title \"$1\"" >/dev/null 2>&1 || true
}
say_ui() {  # say_ui <title> <message> <seconds>
  osascript -e "display dialog \"$2\" with title \"$1\" buttons {\"OK\"} default button 1 giving up after ${3:-4}" \
    >/dev/null 2>&1 || true
}
fail() {
  log "FAIL: $*"
  notify "Media Stack" "$1"
  say_ui "Media Stack — problem" "$1

Check the logs folder in ~/media-stack/logs" 12
  exit 1
}

ensure_docker() {
  if docker info >/dev/null 2>&1; then
    log "docker already running"
    return 0
  fi
  log "docker not running - launching Docker Desktop"
  notify "Media Stack" "Starting Docker…"
  open -a Docker || fail "couldn't launch Docker Desktop"
  local waited=0
  while (( waited < 120 )); do
    docker info >/dev/null 2>&1 && { log "docker up after ${waited}s"; return 0; }
    sleep 3; waited=$((waited + 3))
  done
  fail "Docker didn't start within 2 minutes"
}

wait_for_url() {  # wait_for_url <url> <seconds>
  local url=$1 timeout=$2 waited=0
  while (( waited < timeout )); do
    [[ "$(curl -s -o /dev/null -w '%{http_code}' -m 5 "$url" 2>/dev/null)" != "000" ]] && return 0
    sleep 2; waited=$((waited + 2))
  done
  return 1
}

case "${1:-watch}" in
  watch)
    log "=== watch ==="
    ensure_docker
    notify "Jellyfin" "Starting…"
    docker compose up -d jellyfin >>"$LOG_FILE" 2>&1 || fail "jellyfin failed to start"
    if wait_for_url "http://localhost:8096" 90; then
      log "jellyfin responding, opening browser"
      open "http://localhost:8096"
      notify "Jellyfin" "Ready"
      say_ui "Jellyfin" "Ready — opening in your browser." 3
    else
      fail "Jellyfin didn't come up in time"
    fi
    ;;

  full)
    log "=== full stack ==="
    ensure_docker
    notify "Media Stack" "Starting everything (VPN check included)…"
    say_ui "Media Stack" "Starting everything…

This can take several minutes the first time, or after an update, because Docker images may need downloading. You will get another message when it is ready." 5
    # stack.sh does the VPN leak check and refuses to leave qbittorrent
    # running if torrent traffic isn't behind the tunnel.
    if ./stack.sh up >>"$LOG_FILE" 2>&1; then
      open "http://localhost:5055"
      notify "Media Stack" "Ready - all services up"
      say_ui "Media Stack" "Ready — all services are up.

Opening Jellyseerr. Jellyfin is at localhost:8096" 6
    else
      notify "Media Stack" "Startup failed - opening log"
      open -R "$LOG_FILE"
      exit 1
    fi
    ;;

  stop)
    log "=== stop ==="
    if ! docker info >/dev/null 2>&1; then
      notify "Media Stack" "Docker isn't running - nothing to stop"
      say_ui "Media Stack" "Docker isn't running — nothing to stop." 3
      exit 0
    fi
    docker compose --profile remote down >>"$LOG_FILE" 2>&1 || fail "shutdown had errors"
    log "all containers down"
    notify "Media Stack" "Stopped"
    say_ui "Media Stack" "Stopped — all containers are down." 3
    ;;

  *)
    fail "unknown mode: ${1:-}"
    ;;
esac
