# Ubuntu Server on the N150 mini PC

Target: **Ubuntu Server 26.04 LTS**, Intel N150, 8 GB RAM, headless. Everything below
is done over SSH from the Mac. Commands prefixed `mac$` run on the Mac, everything
else runs on the server.

What is different from the Mac, in one table:

| | Mac (Docker Desktop) | Ubuntu (docker-ce) |
|---|---|---|
| File ownership | Desktop mapped every mount to your Mac user; `PUID` was cosmetic | the container uid **must own** `config/ media/ downloads/` - `PUID`/`PGID` in `.env`, `chown -R` after copying |
| Admin UIs on `127.0.0.1` | you were sitting at the machine | you are not - SSH tunnel, or `ADMIN_BIND=0.0.0.0` |
| Transcoding | CPU / VideoToolbox not reachable from Docker | Intel Quick Sync via `/dev/dri` - **enable it in Jellyfin** |
| Start at boot | `.app` launchers, `open -a Docker` | `systemd/media-stack.service` |
| Memory check in `stack.sh` | `sysctl vm.swapusage` | `/proc/meminfo` (auto-detected) |
| `sqlite3`, `dig` | preinstalled | `sudo apt install sqlite3 dnsutils` (only the `remote` preflight needs them) |

---

## 1. Install Ubuntu

Boot the Ventoy stick, pick `ubuntu-26.04.1-live-server-amd64.iso` in normal mode.
Choices that matter:

- **Storage:** use the entire disk. LVM is fine. Media lives on this disk unless you
  add another later.
- **Profile:** the first user gets uid 1000. Hostname `media` is used in the examples.
- **SSH:** *Install OpenSSH server* = yes. Importing your GitHub SSH key here saves a step.
- **Featured server snaps:** select **nothing**. The Docker snap is not what we want.

After the first login:

```bash
sudo apt update && sudo apt full-upgrade -y && sudo reboot
sudo apt install -y git curl sqlite3 dnsutils intel-gpu-tools
```

Give the box a **static DHCP reservation** on the router now. Jellyseerr's Jellyfin links,
any port forwards, and your SSH muscle memory all point at that address.

## 2. Docker

Use `docker-ce` from Docker's own apt repo (the `docker.io` package lags, the snap is
sandboxed in ways that break bind mounts):

```bash
sudo install -m 0755 -d /etc/apt/keyrings
sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] \
  https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
  | sudo tee /etc/apt/sources.list.d/docker.list >/dev/null
sudo apt update
sudo apt install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
sudo usermod -aG docker "$USER"
```

Log out and back in, then:

```bash
docker info --format '{{.ServerVersion}}'   # a version, no permission error
docker compose version                       # >= 2.17 (the compose file uses depends_on restart: true)
```

`docker.service` is enabled at boot by the package.

## 3. Get the stack

```bash
git clone -b pc https://github.com/claycantrell/clays-media-stack.git ~/media-stack
cd ~/media-stack
cp .env.example .env && chmod 600 .env
mkdir -p config data/media/{movies,tv} data/downloads/{complete,incomplete} logs
```

Fill in `.env`: the ProtonVPN credentials, and confirm `PUID`/`PGID` match `id -u` / `id -g`
(1000/1000 on a fresh install).

## 4. Migrate from the Mac

Skip this for a fresh start. To keep the library, watch history, requests, indexers and
API keys, copy `config/` (and the media, if you want it) from the Mac.

```bash
mac$ cd ~/media-stack && ./stack.sh down          # databases must be closed
mac$ rsync -avh --progress config/ media@media:~/media-stack/config/
mac$ rsync -avh --progress media/  media@media:~/media-stack/data/media/       # optional, big
mac$ rsync -avh --progress downloads/ media@media:~/media-stack/data/downloads/ # optional
```

Then on the server, make the files belong to the uid the containers run as:

```bash
sudo chown -R "$(id -u):$(id -g)" ~/media-stack/{config,data}
```

That `chown` is the step Docker Desktop hid from you. Without it Sonarr/Radarr fail to
import ("Access to the path is denied") and Jellyfin can't write its database.

Media, TV and downloads now live under a single `/data` mount (so Radarr/Sonarr
**hardlink** on import instead of copying — no duplicate files, no wasted space). If you
are migrating a config from the Mac (where the paths were `/movies`, `/tv`, `/downloads`),
repoint three things after first start, or imports land in the wrong place:

- **Radarr → Settings → Media Management → Root Folders:** `/data/media/movies`
- **Sonarr → root folder:** `/data/media/tv`
- **qBittorrent → Options → Downloads → Default Save Path:** `/data/downloads/complete`
  (temp `/data/downloads/incomplete`)

Two more things do **not** carry over:

- **Jellyseerr → Settings → Jellyfin → External URL** still points at the Mac's LAN IP.
  Change it to `http://<server-lan-ip>:8096`.
- The `.env` file. Copy the ProtonVPN lines by hand; keep `PUID`/`PGID` at 1000.

## 5. First start

```bash
cd ~/media-stack && ./stack.sh up
```

Same preflight, VPN leak check and web-UI polling as before. The summary now prints the
LAN address other devices should use. Open `http://<server-lan-ip>:8096` from the Mac.

## 6. Hardware transcoding (Quick Sync)

The compose file passes `/dev/dri` to Jellyfin. Confirm the kernel exposes the iGPU:

```bash
ls -l /dev/dri            # expect card0 and renderD128
sudo intel_gpu_top        # q to quit; shows the N150's GPU engines
```

Then switch it on - this is a UI setting, not a compose one:

**Jellyfin → Dashboard → Playback → Transcoding**

- Hardware acceleration: **Intel QuickSync (QSV)**
- QSV device: `/dev/dri/renderD128`
- Enable hardware decoding for: H264, HEVC, HEVC 10bit, VP9, AV1 (the N150 does all of these)
- Enable hardware encoding: on
- Allow encoding in HEVC: on

Verify: play something on a client that forces a transcode (drop the quality in the
player), then `sudo intel_gpu_top` should show the Video engine busy and `top` should not
show ffmpeg pinning a core. With the 1080p HEVC profile most playback is direct play
anyway; this matters for remote viewers and older TVs.

## 7. Reaching the admin UIs

By default Sonarr, Radarr, Prowlarr, qBittorrent and FlareSolverr are published on
`127.0.0.1` **on the server**, where nothing of yours has a browser. Two options.

**SSH tunnel (default, no config change).** From the Mac:

```bash
mac$ ssh -N -L 8989:localhost:8989 -L 7878:localhost:7878 -L 9696:localhost:9696 -L 8080:localhost:8080 media@media
```

then `http://localhost:8989` etc. in the Mac browser work exactly as before. Put it in
`~/.ssh/config` as a `LocalForward` block if you use it often.

**Publish on the LAN.** Set `ADMIN_BIND=0.0.0.0` in `.env`, `./stack.sh up`. These UIs
have no authentication, so anyone on the LAN can change indexers or delete downloads.
If you go this way, turn on auth in each app (Settings → General → Authentication → Forms)
and set a qBittorrent WebUI password - note qBittorrent still whitelists `10.89.0.0/16`,
which is the Docker network, not the LAN, so Sonarr/Radarr keep working.

## 8. Start at boot

Docker's `restart: unless-stopped` already brings every container back after a reboot,
but that path skips the VPN leak check. The systemd unit runs `stack.sh up` instead:

```bash
sed "s/USERNAME/$USER/g" systemd/media-stack.service | sudo tee /etc/systemd/system/media-stack.service
sudo systemctl daemon-reload
sudo systemctl enable --now media-stack
journalctl -u media-stack -f
```

Reboot once and confirm `./stack.sh status` shows a Swedish egress IP.

## 9. Memory on 8 GB

Steady state is ~2.2 GB of containers plus ~0.5 GB of OS. The `mem_limit` values in the
compose file are **caps**, not reservations; they add up past 8 GB and that is fine.
Give the kernel somewhere to go under a transcoding + import spike:

```bash
free -h                       # the installer usually created a swap file already
sudo apt install -y zram-tools && sudo systemctl enable --now zramswap   # compressed RAM swap, cheap on an N150
```

`stack.sh` warns when less than ~2.5 GB is available at start.

## 10. Firewall and exposure

Ubuntu Server ships with `ufw` inactive. Docker-published ports bypass `ufw` anyway, so
the `127.0.0.1` binds are still what protects the admin UIs - same story as on the Mac.
If you do enable `ufw`, allow SSH first: `sudo ufw allow OpenSSH && sudo ufw enable`.

The `remote` profile ([REMOTE-ACCESS.md](REMOTE-ACCESS.md)) is unchanged: forward 80/443
to the server's reserved LAN IP instead of the Mac. Its preflight needs `sqlite3` and
uses `dig` when present (falls back to `getent` otherwise).

## 11. Keeping it updated

```bash
sudo apt update && sudo apt upgrade -y             # OS; reboot if the kernel changed
cd ~/media-stack && docker compose pull && ./stack.sh up   # images
docker image prune -f                              # reclaim old layers
```

`unattended-upgrades` is on by default for security updates; it will not touch Docker
images.

## Troubleshooting (Linux-specific)

| Symptom | Cause | Fix |
|---|---|---|
| `permission denied while trying to connect to the Docker daemon socket` | not in the `docker` group yet | `sudo usermod -aG docker $USER`, log out and in |
| Sonarr/Radarr "Access to the path is denied", Jellyfin `unable to open database` | files owned by a different uid than `PUID` | `sudo chown -R 1000:1000 config media downloads`; check `.env` |
| `error gathering device information while adding custom device "/dev/dri"` | no iGPU device node | `ls /dev/dri`; `dmesg \| grep i915`; kernel too old or iGPU disabled in BIOS |
| Jellyfin transcodes on CPU | QSV not switched on | §6 - it is a dashboard setting |
| gluetun: `/dev/net/tun` missing | tun module not loaded | `sudo modprobe tun`; it is built in on stock Ubuntu kernels |
| Admin UI unreachable from the Mac | published on `127.0.0.1` of the **server** | SSH tunnel or `ADMIN_BIND` (§7) |
