# Media Stack

Self-hosted media automation: request → grab over VPN → auto-import → stream.

Request things in **Jellyseerr**, watch them in **Jellyfin**. Everything between those
two runs itself.

---

## Quick start

```bash
cd ~/media-stack
./stack.sh up
```

`stack.sh` is the only command you need. It does more than `docker compose up`:

| Step | What it checks |
|---|---|
| Preflight | Docker running, `.env` present, compose config valid |
| Memory | warns if swap is >80% used (this stack wants ~2.2 GB) |
| VPN | waits for gluetun healthy, then **compares torrent egress IP to your real IP** |
| Leak guard | if they match — or the egress IP can't be read — it **stops qBittorrent and aborts** |
| Services | polls all six web UIs until they actually answer |

Other commands:

```bash
./stack.sh down            # stop + remove containers (config/media/downloads untouched)
./stack.sh status          # what's running + current VPN egress IP
./stack.sh logs sonarr     # tail one service (or all, if omitted)
./stack.sh remote up       # ALSO expose to the internet - see docs/REMOTE-ACCESS.md
./stack.sh remote down     # close public access, leave the media stack running
```

Every run is logged to `logs/stack-<timestamp>.log`.

**Remote access is off by default.** Caddy and CrowdSec live behind the `remote`
Compose profile, so a plain `./stack.sh up` never starts them. Setup is documented
in **[docs/REMOTE-ACCESS.md](docs/REMOTE-ACCESS.md)** — it needs a domain, router
port forwarding, and a Jellyfin admin password, and `./stack.sh remote up` hard-fails
until all three exist.

---

## Services

| Service | Port | URL | Purpose |
|---|---|---|---|
| Jellyfin | 8096 | http://localhost:8096 | Media server — **watch here** |
| Jellyseerr | 5055 | http://localhost:5055 | Request portal — **request here** |
| Radarr | 7878 | http://localhost:7878 | Movie automation |
| Sonarr | 8989 | http://localhost:8989 | TV automation |
| Prowlarr | 9696 | http://localhost:9696 | Indexer manager |
| qBittorrent | 8080 | http://localhost:8080 | Torrent client (via VPN) |
| FlareSolverr | 8191 | http://localhost:8191 | Cloudflare bypass for indexers |
| gluetun | — | no UI | ProtonVPN tunnel (qBittorrent shares its netns) |
| auto-trackers | — | no UI | Injects public trackers into trackerless magnets |

**Use `localhost`, not `jellyfin`.** Service names like `jellyfin` and `gluetun` only
resolve *inside* the Docker network — a browser can't reach them.

---

## The pipeline

```
Jellyseerr  →  Radarr / Sonarr  →  Prowlarr  →  qBittorrent  →  import  →  Jellyfin
  request        decide + grab      indexers    (through VPN)    rename       watch
```

1. You request a title in Jellyseerr.
2. Radarr (movies) or Sonarr (TV) picks a release matching the quality profile.
3. Prowlarr searches the configured indexers.
4. qBittorrent downloads it inside gluetun's network namespace.
5. Radarr/Sonarr move and rename it into `media/movies` or `media/tv`.
6. **Radarr/Sonarr notify Jellyfin on import**, so it appears immediately.

Watch progress in **Radarr → Activity → Queue** (or Sonarr for TV). That single page
shows the grab, download progress, and import.

---

## Folder layout

```
media-stack/
├── stack.sh                ← start/stop/status (use this)
├── docker-compose.yml      ← service definitions
├── .env                    ← ProtonVPN credentials (chmod 600, gitignored)
├── .gitignore
├── README.md               ← this file
├── scripts/
│   └── auto-trackers.py    ← tracker injector for trackerless magnets
├── caddy/                  ← reverse proxy for remote access (inert until used)
│   ├── Dockerfile          ← custom Caddy build: ratelimit + crowdsec modules
│   └── Caddyfile
├── crowdsec/
│   └── acquis.yaml         ← which logs CrowdSec watches
├── docs/
│   └── REMOTE-ACCESS.md    ← how to expose this to the internet safely
├── config/                 ← ALL service state: databases, settings, API keys
│   ├── gluetun/ qbittorrent/ prowlarr/ sonarr/ radarr/ jellyfin/ jellyseerr/
├── downloads/              ← qBittorrent working dir
│   ├── complete/  incomplete/
├── media/                  ← Radarr/Sonarr import here, Jellyfin reads here
│   ├── movies/  tv/
├── logs/                   ← stack.sh run logs
└── backups/                ← archived compose files
```

`config/`, `downloads/`, `media/`, and `scripts/auto-trackers.py` are **bind-mounted
into containers**. Moving or renaming them breaks the stack. `config/` is the whole
backup surface — it holds every database, setting, and API key.

---

## Secrets

Deliberately **not** listed in this file, so the README stays safe to copy around.
Retrieve them from where they actually live:

```bash
# *arr API keys
grep -o '<ApiKey>[^<]*</ApiKey>' config/radarr/config.xml   | sed 's/<[^>]*>//g'
grep -o '<ApiKey>[^<]*</ApiKey>' config/sonarr/config.xml   | sed 's/<[^>]*>//g'
grep -o '<ApiKey>[^<]*</ApiKey>' config/prowlarr/config.xml | sed 's/<[^>]*>//g'

# Jellyseerr API key
python3 -c "import json;print(json.load(open('config/jellyseerr/settings.json'))['main']['apiKey'])"

# Jellyfin API keys (stack must be up)
sqlite3 config/jellyfin/data/data/jellyfin.db "select Name from ApiKeys;"

# ProtonVPN credentials
cat .env
```

**Logins**

- **Jellyfin** — user `admin`, **no password set**. Jellyseerr authenticates through
  Jellyfin, so this is also your Jellyseerr login (leave the password field empty).
- **qBittorrent** — the WebUI has a password, but Sonarr/Radarr don't use it: they're
  exempted by `WebUI\AuthSubnetWhitelist=10.89.0.0/16` (see *Pinned subnet* below).
- **Radarr / Sonarr / Prowlarr / FlareSolverr** — no auth, local access only.

> ⚠️ **Jellyfin's admin account has a blank password**, and both Jellyfin (8096) and
> Jellyseerr (5055) bind to `0.0.0.0`. Anyone on your LAN can reach them and get an
> admin session by typing `admin` and pressing enter. Jellyfin admin also allows
> arbitrary filesystem browsing when adding libraries. Fix at
> *Jellyfin → Dashboard → Users → admin → Password*; Jellyseerr picks it up on next
> login. Alternatively bind to `127.0.0.1:8096:8096` if you only watch on this Mac.

---

## VPN

ProtonVPN via OpenVPN, exiting in **Sweden**, with port forwarding on. Credentials live
in `.env` and are referenced as `${OPENVPN_USER:?...}` in the compose file — if `.env`
goes missing, the stack **refuses to start** rather than quietly running the VPN
unauthenticated.

qBittorrent uses `network_mode: service:gluetun`, so it has no network path of its own.
If the tunnel drops, it loses connectivity entirely instead of falling back to your real IP.

Verify manually:

```bash
docker exec gluetun wget -qO- https://ipinfo.io/json   # should be Sweden, not your ISP
curl -s https://ipinfo.io/ip                           # your real IP, for comparison
docker exec gluetun cat /tmp/gluetun/forwarded_port    # current forwarded port
```

`./stack.sh up` does this automatically on every start.

---

## Seeding

`Session\GlobalMaxRatio=0` with `ShareLimitAction=Stop` — torrents **stop as soon as
they finish downloading**, and are paused rather than deleted, so files stay put.

This doesn't mean zero upload: BitTorrent trades pieces in both directions *while*
downloading, and no setting changes that. What it removes is the long tail of seeding
after completion. Change it in `config/qbittorrent/qBittorrent/qBittorrent.conf`
(`0` = never seed, `1.0` = seed back what you took, `-1` = unlimited).

---

## Startup ordering

`depends_on` alone only waits for a container to *start*, not to be *ready* — which
previously let Prowlarr query Cloudflare-gated indexers before FlareSolverr was up,
failing them into a 6-hour backoff. Now:

- **FlareSolverr** has a healthcheck against its `/health` endpoint.
- **Prowlarr** waits for `condition: service_healthy`.
- **qBittorrent** waits for gluetun to be healthy before starting on its netns.

## Pinned subnet

The `media-stack` network pins `subnet: 10.89.0.0/16`. This is **load-bearing**:
qBittorrent's `WebUI\AuthSubnetWhitelist` is set to that range, and it's how Sonarr and
Radarr reach the qBittorrent API without credentials.

Docker allocates subnets from a shared pool, and other projects on this machine create
networks too. Without the pin, a rebuilt `media-stack` network could land on a different
subnet — and Sonarr/Radarr would silently lose their download client with no obvious
error. If you ever change one, change both.

**Why `10.89` and not something in `172.x`:** Docker's default pool is
`172.17.0.0/16` through `172.31.0.0/16`. The Supabase worktree stacks on this machine
allocate from that pool and have already claimed `172.18`–`172.25`, gaining another
each time a new worktree spins up. This network was originally pinned to `172.19`,
which a new `oncall-w8` worktree took hours later — producing
`invalid pool request: Pool overlaps with other one on this address space` on the next
start. `10.89` sits outside the default pool entirely, so it can't be claimed out from
under this stack.

---

## Wiring

- **Prowlarr → Radarr & Sonarr** — `fullSync`. Indexers added in Prowlarr push to both.
- **Radarr/Sonarr → qBittorrent** — at `gluetun:8080`, categories `radarr` / `tv-sonarr`.
- **Radarr/Sonarr → Jellyfin** — `MediaBrowser` connection firing on import, upgrade,
  and rename, so Jellyfin updates immediately instead of waiting for a scheduled scan.
- **Jellyseerr → Jellyfin/Sonarr/Radarr** — internal hostnames; external URL set to
  `http://172.16.0.2:8096` so "Play on Jellyfin" links work from a browser.
- **auto-trackers** — polls qBittorrent every 60s and injects the
  [ngosang trackerslist](https://ngosang.github.io/trackerslist/) into any torrent with
  no real trackers, then force-reannounces. Public-indexer magnets often ship with none,
  and qBittorrent's built-in tracker auto-add only applies to `.torrent` files.

> `172.16.0.2` is DHCP-assigned. If the lease changes, Jellyseerr's Jellyfin links break
> until you update the external URL. A static DHCP reservation makes it permanent.

---

## Quality profiles

Both apps use a tightened `HD-1080p` profile:

- Allowed: HDTV-1080p, WEBDL-1080p, WEBRip-1080p, Bluray-1080p
- Rejected: anything below 1080p, Remux-1080p, 2160p/4K and above
- Cutoff: WEB-1080p
- Size cap: 80 MB/min movies (~8 GB for a 100-min film), 70 MB/min TV (~3 GB/episode)

---

## Known limitations

- **LimeTorrents won't sync to Radarr.** Radarr validates new indexers with a blank
  search on category 2000 (Movies); LimeTorrents returns nothing for that probe, so
  Radarr rejects it with `400 BadRequest` — even with `forceSave=true`. This is indexer
  behaviour meeting Radarr's validation rule, not a fixable setting. Sonarr accepts it
  fine, so it's available for TV only. Knaben trips the same rule intermittently.
- **Docker's VM allocation.** Containers use ~2.2 GB, but Docker Desktop reserves ~9.7 GB
  of the Mac's 16 GB by default. Stopping containers does **not** hand that back to
  macOS — only lowering the allocation (Settings → Resources → Memory) or quitting
  Docker Desktop does. On a machine already deep into swap, this is the lever that matters.

---

## Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| Item downloaded but not in Jellyfin | Jellyfin hasn't rescanned | Should be automatic now; force with *Jellyfin → Dashboard → Scheduled Tasks → Scan Media Library* |
| Item in Jellyfin but Jellyseerr still says "Processing" | Jellyseerr syncs on a timer | *Settings → Jobs* → run `Jellyfin Recently Added Scan` + `Media Availability Sync` |
| Safari: "can't find server 'jellyfin'" | Using an internal Docker hostname | Use `http://localhost:8096` |
| Indexer "unavailable due to failures" | FlareSolverr was down when Prowlarr queried it | *Prowlarr → Indexers → Test* to clear the backoff. Both Prowlarr **and** each *arr keep separate backoff state — clear all three |
| Sonarr/Radarr can't reach download client | network subnet drifted off `10.89.0.0/16` | Check `docker network inspect media-stack`; see *Pinned subnet* |
| `Pool overlaps with other one on this address space` | another project claimed the pinned subnet | Pick a free range outside Docker's default `172.17–172.31` pool, and update **both** compose and `qBittorrent.conf` |
| qBittorrent stalled, peers = 0 | listen port out of sync with VPN forwarded port | `docker exec gluetun cat /tmp/gluetun/forwarded_port`, compare to qBittorrent → Settings → Connection |
| Stack won't start, `required variable OPENVPN_USER` | `.env` missing or unreadable | Restore `.env` (this failure is intentional — it prevents an unauthenticated VPN) |
| Everything sluggish, containers OOM-killed | Mac is out of RAM / swap full | `sysctl vm.swapusage`; lower Docker's memory allocation |

---

## Backup & migration

`config/` is everything — databases, settings, API keys, watch history, requests.

```bash
./stack.sh down
tar -czf media-stack-config-$(date +%Y%m%d).tar.gz \
  docker-compose.yml stack.sh README.md .env config/
```

On the new machine: extract, `mkdir -p media/{movies,tv} downloads/{complete,incomplete}`,
adjust `PUID`/`PGID` in `docker-compose.yml` if your UID isn't 501/20, then `./stack.sh up`.

Container-internal paths (`/movies`, `/tv`, `/data/movies`) don't change, and host mounts
are relative, so they follow the folder.

---

## Notes

- LAN-only. To watch away from home, use Tailscale or a reverse proxy with HTTPS.
- `.env`, `config/`, `media/`, `downloads/`, `logs/`, and `backups/` are gitignored.
  This README is deliberately secret-free, but `config/` never is.
- Storage grows fast. The Mac's 460 GB drive is at ~90% — a mini PC with an NVMe
  (Beelink S12 Pro, GMKtec NucBox G3, any N100 box) is the real long-term home.
