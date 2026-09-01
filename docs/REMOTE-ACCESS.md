# Remote access

Letting someone non-technical (e.g. a family member) watch from anywhere, without
installing a VPN client.

**Design:** they get a URL and a Jellyfin login. Nothing else.

```
        internet
           │
      ┌────┴─────┐
      │  Caddy   │  TLS, rate limiting, CrowdSec enforcement
      └────┬─────┘
     ┌─────┴──────┐
     ▼            ▼
  jellyfin    jellyseerr
   :8096         :5055
```

Everything is already written and committed to the repo. **Nothing is live** —
the Caddy and CrowdSec services sit behind the `remote` Compose profile, so a
normal `./stack.sh up` ignores them entirely.

---

## Status

| Piece | State |
|---|---|
| `caddy/Dockerfile` — Caddy + ratelimit + CrowdSec modules | written, **never built** |
| `caddy/Caddyfile` — both hostnames, rate limits, headers | written, **never validated** |
| `crowdsec/acquis.yaml` — log parsing | written |
| Compose services behind `profile: remote` | written, verified inert |
| `./stack.sh remote up` — preflight gate | written, gate verified |
| A domain | **you still need this** |
| Jellyfin admin password | **blocker — see below** |
| Router port forwarding | you still need this |

The Caddyfile and Dockerfile have never been executed — building requires
pulling images and running containers. Expect to fix a typo or two on first run;
that's normal and the preflight will keep it from being a public typo.

---

## Blocker: the Jellyfin password

Jellyfin currently has **one admin account with no password at all**. On your LAN
that's untidy. Exposed to the internet it's an open admin account — and Jellyfin
admin can browse the host filesystem when adding libraries.

`./stack.sh remote up` **refuses to start** while any passwordless account exists:

```
FAIL Jellyfin has 1 account(s) with NO password. Set one before exposing this.
```

To clear it (needs the stack running, all local):

1. `./stack.sh up`, open <http://localhost:8096>
2. Dashboard → Users → `admin` → Password → set one
3. Dashboard → Users → **+** → add an account for each viewer
   - give it library access only
   - leave every admin checkbox off
4. Jellyseerr authenticates against Jellyfin, so one login works for both

---

## Setup

### 1. Domain

Any registrar. Point the nameservers at Cloudflare (free tier). Then create two
records — **the proxy setting differs and it matters:**

| Record | Type | Value | Cloudflare proxy |
|---|---|---|---|
| `watch` | A | your public IP | **DNS only (grey)** |
| `request` | A | your public IP | proxied (orange) is fine |

`watch` **must be grey.** Cloudflare's CDN terms restrict serving video hosted
outside Cloudflare. Grey cloud means they answer DNS and the video goes directly
from this Mac to the viewer, which keeps you out of that rule entirely.

`request` is HTML and small API calls, so proxying is fine and gets you their WAF.

### 2. Router

Forward TCP **80** and **443** to this Mac's LAN address. Port 80 is required —
Let's Encrypt uses it for the HTTP-01 challenge.

Your LAN IP is DHCP-assigned. Give this Mac a static DHCP reservation, or the forward
will silently point at the wrong device one day.

Your *public* IP is probably dynamic too. If it changes, the A records go stale —
use your registrar's DDNS or a Cloudflare DDNS updater.

### 3. Fill in `.env`

```bash
DOMAIN_WATCH=watch.yourdomain.com
DOMAIN_REQUEST=request.yourdomain.com
CROWDSEC_API_KEY=            # left blank for now - see next step
```

### 4. Bootstrap the CrowdSec key

Chicken-and-egg: Caddy needs a bouncer key, but only a running CrowdSec can mint
one. So start CrowdSec alone first:

```bash
cd ~/media-stack
docker compose --profile remote up -d crowdsec
docker exec crowdsec cscli bouncers add caddy-bouncer
```

Copy the key it prints into `CROWDSEC_API_KEY` in `.env`.

### 5. Go live

```bash
./stack.sh remote up
```

This builds the custom Caddy image (a few minutes the first time), runs every
preflight check, and brings up the full stack plus the public endpoints.

Certificates are automatic — Caddy requests them from Let's Encrypt on first
start. If the domain doesn't resolve yet, it will retry; watch with
`./stack.sh logs caddy`.

### 6. Verify before handing out the URL

```bash
curl -sI https://watch.yourdomain.com | head -3        # expect 200/302, valid TLS
dig +short watch.yourdomain.com                        # expect YOUR ip, not Cloudflare's
./stack.sh logs caddy                                  # watch a real request land
```

Then log in as a non-admin viewer account from a device that isn't on your network —
cellular data on a phone is the honest test.

---

## Closing it back down

```bash
./stack.sh remote down     # stops Caddy + CrowdSec, media stack keeps running
```

Public access ends immediately. Nothing else is affected.

---

## Optional: one app instead of two

By default a viewer uses Jellyfin to watch and Jellyseerr to request — two icons,
one password.

[JellyBridge](https://github.com/kinggeorges12/JellyBridge) is a Jellyfin plugin
that collapses those into one: it adds a discover library inside Jellyfin, and
**marking something as a favorite fires the Jellyseerr request automatically.**
Favorites are a native Jellyfin feature, so this works in the official iOS,
Android, and Android TV apps — not just the web UI.

Two caveats worth weighing first:

- **Version gap.** It requires Jellyfin 10.10.0+ and is tested to **10.11.6**.
  This stack runs **10.11.8**, and the project warns plugin versions must match
  specific Jellyfin versions.
- **It wants a patched Jellyseerr image** for request approvals — a third-party
  build replacing the official `fallenbagel/jellyseerr`.

Try it on the LAN before anything is public. If it misbehaves, two icons is a
perfectly good outcome.

Repo to add in Jellyfin → Dashboard → Plugins → Repositories:

```
https://raw.githubusercontent.com/kinggeorges12/JellyBridge/refs/heads/main/manifest.json
```

---

## Hardening notes

Already in the config:

- **Rate limiting** on `/Users/AuthenticateByName` (5/min/IP) — the endpoint
  attackers hammer, and the one that accepted a blank password before you fixed it.
- **CrowdSec** with the `crowdsecurity/caddy` and `LePresidente/jellyfin`
  collections. Note that fail2ban on a Docker host often *doesn't* work, because
  Docker's networking bypasses host iptables rules — enforcing at Caddy avoids that.
- **Security headers** — HSTS, nosniff, frame options, server header suppressed.

Worth adding later:

- **GeoIP allow-list.** If every legitimate viewer is in one country, blocking the
  rest removes most automated traffic. Easiest via Cloudflare WAF on the `request`
  hostname; needs the maxmind Caddy module for `watch`.
- **Keep Jellyfin updated.** It's exposed now; `docker compose pull` periodically.
- **Admin stays local.** Don't use the admin account remotely.

Useful commands:

```bash
docker exec crowdsec cscli decisions list      # who's currently blocked
docker exec crowdsec cscli alerts list         # what was detected
docker exec crowdsec cscli metrics             # parser health
```
