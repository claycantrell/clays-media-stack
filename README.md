# Media Stack

Self-hosted media automation: request → grab over VPN → auto-import → stream.

Request things in **Jellyseerr**, watch them in **Jellyfin**. Everything between those
two runs itself.

---

## Quick start

**On the Ubuntu mini PC?** Do [docs/UBUNTU-SERVER.md](docs/UBUNTU-SERVER.md) first -
Docker install, `.env`, migrating `config/` from the Mac, Quick Sync, boot service.

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

| Service | Port | URL | Reachable from | Purpose |
|---|---|---|---|---|
| Jellyfin | 8096 | http://localhost:8096 | **the LAN** | Media server — **watch here** |
| Jellyseerr | 5055 | http://localhost:5055 | **the LAN** | Request portal — **request here** |
| Radarr | 7878 | http://localhost:7878 | this host only | Movie automation |
| Sonarr | 8989 | http://localhost:8989 | this host only | TV automation |
| Prowlarr | 9696 | http://localhost:9696 | this host only | Indexer manager |
| qBittorrent | 8080 | http://localhost:8080 | this host only | Torrent client (via VPN) |
| FlareSolverr | 8191 | http://localhost:8191 | this host only | Cloudflare bypass for indexers |
| gluetun | — | no UI | — | ProtonVPN tunnel (qBittorrent shares its netns) |
| auto-trackers | — | no UI | — | Injects public trackers into trackerless magnets |
| Recyclarr | — | no UI | — | Syncs TRaSH Guides profiles + custom formats daily |
| autoheal | — | no UI | — | Restarts any container its own healthcheck fails |

**Use `localhost`, not `jellyfin`.** Service names like `jellyfin` and `gluetun` only
resolve *inside* the Docker network — a browser can't reach them.

---

## Port exposure

Only the two services other people actually use are published on `0.0.0.0`:

```
jellyfin        0.0.0.0:8096     watch      - LAN clients and the remote profile
jellyseerr      0.0.0.0:5055     request    - LAN clients and the remote profile
gluetun         0.0.0.0:6881     peer port  - inbound torrent connections
radarr        127.0.0.1:7878     admin
sonarr        127.0.0.1:8989     admin
prowlarr      127.0.0.1:9696     admin
qbittorrent   127.0.0.1:8080     admin      (published by gluetun - shared netns)
flaresolverr  127.0.0.1:8191     internal
```

The admin UIs have **no authentication at all**, so the binding *is* the access
control — a `127.0.0.1` publish means nothing on the LAN can open a socket to them,
which is a stronger guarantee than an unauthenticated service behind a login-less
page. On a headless server, reach them through an SSH tunnel (see
[docs/UBUNTU-SERVER.md](docs/UBUNTU-SERVER.md)) or set `ADMIN_BIND=0.0.0.0` in `.env`
to publish them on the LAN. Verify from another machine:

```bash
curl -m 3 http://<server-lan-ip>:8989   # should fail to connect
curl -m 3 http://<server-lan-ip>:8096   # should answer
```

`6881` stays public deliberately: it's the torrent peer port, and closing it makes
gluetun's port forwarding pointless. Remote access does **not** need any of these
publishes — Caddy reaches `jellyfin:8096` and `jellyseerr:5055` over the Docker
network by container name.

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
5. Radarr/Sonarr move and rename it into `data/media/movies` or `data/media/tv`.
6. **Radarr/Sonarr notify Jellyfin on import**, so it appears immediately.

Watch progress in **Radarr → Activity → Queue** (or Sonarr for TV). That single page
shows the grab, download progress, and import.

---

## Folder layout

```
media-stack/
├── stack.sh                ← start/stop/status (use this)
├── docker-compose.yml      ← service definitions
├── .env                    ← ProtonVPN credentials + host knobs (chmod 600, gitignored)
├── .env.example            ← template for .env
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
│   ├── UBUNTU-SERVER.md    ← setting up / migrating to the Ubuntu mini PC
│   └── REMOTE-ACCESS.md    ← how to expose this to the internet safely
├── systemd/
│   └── media-stack.service ← start the stack (with VPN check) at boot on Linux
├── config/                 ← ALL service state: databases, settings, API keys
│   ├── gluetun/ qbittorrent/ prowlarr/ sonarr/ radarr/ jellyfin/ jellyseerr/
│   └── recyclarr/          ← TRaSH sync config (holds Sonarr/Radarr API keys)
├── data/                   ← ONE bind mount (/data) so imports HARDLINK, never copy
│   ├── downloads/          ← qBittorrent working dir
│   │   ├── complete/  incomplete/
│   └── media/              ← Radarr/Sonarr import here, Jellyfin reads here
│       ├── movies/  tv/
├── logs/                   ← stack.sh run logs
└── backups/                ← archived compose files
```

`config/`, `data/`, and `scripts/auto-trackers.py` are **bind-mounted
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

# Recyclarr's copies of the Sonarr/Radarr keys
grep -h 'api_key:' config/recyclarr/configs/*.yml
```

**Logins**

- **Jellyfin** — user `admin`, **no password set**. Jellyseerr authenticates through
  Jellyfin, so this is also your Jellyseerr login (leave the password field empty).
- **qBittorrent** — the WebUI has a password, but Sonarr/Radarr don't use it: they're
  exempted by `WebUI\AuthSubnetWhitelist=10.89.0.0/16` (see *Pinned subnet* below).
- **Radarr / Sonarr / Prowlarr / FlareSolverr** — no auth. They are bound to
  `127.0.0.1` (see *Port exposure*), so "local access only" is enforced by the
  socket rather than by a password.

> ⚠️ **Jellyfin's admin account has a blank password**, and Jellyfin (8096) and
> Jellyseerr (5055) are the two services still bound to `0.0.0.0`. Anyone on your LAN
> can reach them and get an admin session by typing `admin` and pressing enter.
> Jellyfin admin also allows arbitrary filesystem browsing when adding libraries.
> Fix at *Jellyfin → Dashboard → Users → admin → Password*; Jellyseerr picks it up on
> next login. Moving these to `127.0.0.1` is not an option unless you only ever watch
> on this machine — they are the whole point of the stack being reachable.

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
failing them into a 6-hour backoff. Now every service with an HTTP endpoint has a
healthcheck, and dependents wait on `condition: service_healthy`:

| Service | Probe |
|---|---|
| gluetun | built into the image |
| FlareSolverr | `/health` |
| Prowlarr / Sonarr / Radarr | `/ping` |
| Jellyfin | `/health` |
| Jellyseerr | `/api/v1/status` |

Sonarr and Radarr additionally carry `restart: true` on their gluetun dependency, so a
VPN flap restarts them instead of leaving them holding a dead download client.

**The probes are not interchangeable.** `fallenbagel/jellyseerr` ships `wget` and no
`curl`; the Jellyfin image ships `curl` and no `wget`. A copy-pasted `curl` healthcheck
on Jellyseerr marks it unhealthy forever — and with autoheal watching, restarts it
every 30 seconds indefinitely. Check the binary exists in the image before writing the
probe:

```bash
docker run --rm --entrypoint sh <image> -c 'command -v curl wget'
```

**autoheal** restarts anything its healthcheck fails, opt-in via the `autoheal=true`
label. gluetun and qBittorrent are deliberately **unlabelled**: qBittorrent lives in
gluetun's network namespace, so an autoheal restart of gluetun would strand it with a
dead network stack. VPN recovery stays with `stack.sh`, which re-verifies egress before
letting torrent traffic resume. Note that autoheal mounts the Docker socket read-write,
which is root-equivalent control of the daemon — unavoidable for something whose job is
restarting containers, but it is a real trade.

## Pinned subnet

The `media-stack` network pins `subnet: 10.89.0.0/16`. This is **load-bearing**:
qBittorrent's `WebUI\AuthSubnetWhitelist` is set to that range, and it's how Sonarr and
Radarr reach the qBittorrent API without credentials.

Docker allocates subnets from a shared pool, and other projects on the same machine
create networks too. Without the pin, a rebuilt `media-stack` network could land on a
different subnet — and Sonarr/Radarr would silently lose their download client with no
obvious error. If you ever change one, change both.

**Why `10.89` and not something in `172.x`:** Docker's default pool is
`172.17.0.0/16` through `172.31.0.0/16`. Any other Compose project on the host draws
from that pool, and long-lived ones accumulate — so a pin *inside* the default range
is a collision waiting to happen. This network was originally pinned to `172.19` and
another project claimed it hours later, producing
`invalid pool request: Pool overlaps with other one on this address space` on the next
start. `10.89` sits outside the default pool entirely, so it can't be taken out from
under this stack.

---

## Wiring

- **Prowlarr → Radarr & Sonarr** — `fullSync`. Indexers added in Prowlarr push to both.
- **Radarr/Sonarr → qBittorrent** — at `gluetun:8080`, categories `radarr` / `tv-sonarr`.
- **Radarr/Sonarr → Jellyfin** — `MediaBrowser` connection firing on import, upgrade,
  and rename, so Jellyfin updates immediately instead of waiting for a scheduled scan.
- **Jellyseerr → Jellyfin/Sonarr/Radarr** — internal hostnames; external URL set to
  the host's LAN address (`http://<lan-ip>:8096`) so "Play on Jellyfin" links work
  from a browser.
- **auto-trackers** — polls qBittorrent every 60s and injects the
  [ngosang trackerslist](https://ngosang.github.io/trackerslist/) into any torrent with
  no real trackers, then force-reannounces. Public-indexer magnets often ship with none,
  and qBittorrent's built-in tracker auto-add only applies to `.torrent` files.

> That LAN address is DHCP-assigned. If the lease changes, Jellyseerr's Jellyfin links
> break until you update the external URL. A static DHCP reservation makes it permanent.

---

## Quality profiles

**In use:** a hand-tightened `HD-1080p` profile in both apps:

- Allowed: HDTV-1080p, WEBDL-1080p, WEBRip-1080p, Bluray-1080p
- Rejected: anything below 1080p, Remux-1080p, 2160p/4K and above
- Cutoff: WEB-1080p
- Size cap: 80 MB/min movies (~8 GB for a 100-min film), 70 MB/min TV (~3 GB/episode)

**Also available, not yet assigned:** Recyclarr syncs the TRaSH Guides profiles daily
and has created `HD Bluray + WEB` in Radarr (40 custom formats) and `WEB-1080p` in
Sonarr (37). Recyclarr creates profiles; it does **not** reassign your library, so
nothing downloads differently until you switch titles onto them. Expect Radarr to start
hunting upgrades on existing files when you do, since the TRaSH cutoff score is higher
than what those files scored.

The stock profiles will show the new custom formats listed against them. That is
cosmetic — Radarr registers custom formats globally, and they are scored `0` in any
profile Recyclarr does not manage.

Config lives in `config/recyclarr/configs/`. Recyclarr is pinned to major version `8`
rather than `:latest`, because its config schema is versioned and a major bump can
invalidate `recyclarr.yml` — the one image here where `:latest` is a hazard rather than
just untidy. It also takes a literal `user:` uid:gid instead of `PUID`/`PGID`, wired
to the same `.env` values.

Run it by hand with:

```bash
docker compose run --rm recyclarr sync --preview   # dry run, changes nothing
docker compose run --rm recyclarr sync             # apply
```

---

## Known limitations

- **LimeTorrents won't sync to Radarr.** Radarr validates new indexers with a blank
  search on category 2000 (Movies); LimeTorrents returns nothing for that probe, so
  Radarr rejects it with `400 BadRequest` — even with `forceSave=true`. This is indexer
  behaviour meeting Radarr's validation rule, not a fixable setting. Sonarr accepts it
  fine, so it's available for TV only. Knaben trips the same rule intermittently.
- **Docker's VM allocation (macOS only).** Containers use ~2.2 GB, but Docker Desktop reserves far
  more than that for its VM by default. Stopping containers does **not** hand the
  reservation back to macOS — only lowering the allocation (Settings → Resources →
  Memory) or quitting Docker Desktop does. Once the host is into swap, this is the
  lever that matters.

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
| Everything sluggish, containers OOM-killed | host is out of RAM / swap full | Linux: `free -h`, add zram/swap (docs/UBUNTU-SERVER.md). macOS: `sysctl vm.swapusage`; lower Docker's memory allocation |
| Every service refuses connections at once, `docker ps` hangs for minutes | the Docker **daemon** is wedged, not the stack | Linux: `sudo systemctl restart docker`. macOS: confirm with `curl -s --unix-socket ~/.docker/run/docker.sock http://x/_ping` — empty means dead. A normal quit often will not clear it: the backend can ignore SIGTERM and survive with the same PID. `pkill -9 -f com.docker` then `open -a Docker` |
| A container restarts every ~30s forever | its healthcheck references a binary the image lacks, and autoheal is acting on the failure | `docker inspect -f '{{json .State.Health}}' <name>`; fix the probe (see *Startup ordering*) |
| Jellyfin transcodes on CPU, fan spins up, playback stutters | Quick Sync not switched on in Jellyfin | Dashboard → Playback → Transcoding → Intel QuickSync; see docs/UBUNTU-SERVER.md |

---

## Backup & migration

`config/` is everything — databases, settings, API keys, watch history, requests.

```bash
./stack.sh down
tar -czf media-stack-config-$(date +%Y%m%d).tar.gz \
  docker-compose.yml stack.sh README.md .env config/
```

On the new machine: extract, `mkdir -p data/media/{movies,tv} data/downloads/{complete,incomplete}`,
set `PUID`/`PGID` in `.env` to the uid/gid that owns those folders (`id -u`, `id -g`;
Ubuntu = 1000/1000) and `chown -R` the copied `config/` to match, then `./stack.sh up`.
The full Mac → Ubuntu walkthrough is in [docs/UBUNTU-SERVER.md](docs/UBUNTU-SERVER.md).

Container-internal paths (`/data/media/movies`, `/data/media/tv`, `/data/movies`) and host mounts
are relative, so they follow the folder.

---

## Notes

- LAN-only by default. To watch away from home, use the `remote` profile
  (Caddy + CrowdSec, see [docs/REMOTE-ACCESS.md](docs/REMOTE-ACCESS.md)).
- `.env`, `config/`, `media/`, `downloads/`, `logs/`, and `backups/` are gitignored.
  This README is deliberately secret-free, but `config/` never is.
- Storage grows fast. Media fills a laptop SSD quickly; this stack's long-term home is
  the N150 mini PC running Ubuntu Server (see [docs/UBUNTU-SERVER.md](docs/UBUNTU-SERVER.md)).
