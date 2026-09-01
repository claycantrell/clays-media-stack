#!/usr/bin/env python3
"""Watches qBittorrent and injects public trackers into any torrent that has
none (typical of magnets returned by public indexers like 1337x/TPB/Knaben).
Tracker list is pulled from ngosang/trackerslist, refreshed daily."""

import json, os, time, urllib.parse, urllib.request
from http.cookiejar import CookieJar

QBIT_HOST = os.environ.get("QBIT_HOST", "http://localhost:8080")
# No credential defaults on purpose. qBittorrent is configured with
# WebUI\LocalHostAuth=false and an AuthSubnetWhitelist covering the compose
# network, so this script authenticates by origin rather than by password. If
# you tighten either of those, supply QBIT_USER/QBIT_PASS via the environment.
QBIT_USER = os.environ.get("QBIT_USER", "")
QBIT_PASS = os.environ.get("QBIT_PASS", "")
TRACKER_URL = os.environ.get(
    "TRACKER_URL",
    "https://raw.githubusercontent.com/ngosang/trackerslist/master/trackers_best.txt",
)
CHECK_INTERVAL = int(os.environ.get("CHECK_INTERVAL", "60"))
LIST_REFRESH = int(os.environ.get("LIST_REFRESH", "86400"))
LOGIN_INTERVAL = 1800

cookie_jar = CookieJar()
opener = urllib.request.build_opener(urllib.request.HTTPCookieProcessor(cookie_jar))


def log(msg):
    print(f"[{time.strftime('%H:%M:%S')}] {msg}", flush=True)


def fetch_trackers():
    with opener.open(urllib.request.Request(TRACKER_URL), timeout=15) as r:
        text = r.read().decode("utf-8")
    return [l.strip() for l in text.splitlines() if l.strip() and not l.startswith("#")]


def post(path, data):
    body = urllib.parse.urlencode(data).encode()
    with opener.open(f"{QBIT_HOST}{path}", data=body, timeout=10) as r:
        return r.read().decode()


def get(path):
    with opener.open(f"{QBIT_HOST}{path}", timeout=10) as r:
        return json.loads(r.read())


def login():
    return "Ok" in post("/api/v2/auth/login", {"username": QBIT_USER, "password": QBIT_PASS})


def api_reachable():
    """True if the API answers without a session.

    qBittorrent here runs with WebUI\\LocalHostAuth=false, and this script shares
    gluetun's network namespace - so its requests arrive on loopback and are
    authenticated by origin. In that configuration /auth/login returns "Fails."
    for every credential pair, including the right one, because there is no
    password check to pass. Gating the loop on login() therefore blocked the
    injection code permanently.
    """
    try:
        with opener.open(f"{QBIT_HOST}/api/v2/app/version", timeout=10) as r:
            r.read()
        return True
    except Exception:
        return False


trackers, last_refresh, last_login = [], 0, 0

log("auto-trackers starting")
while True:
    try:
        now = time.time()

        if now - last_refresh > LIST_REFRESH or not trackers:
            try:
                trackers = fetch_trackers()
                last_refresh = now
                log(f"refreshed tracker list ({len(trackers)} entries)")
            except Exception as e:
                log(f"tracker fetch failed: {e}")
                if not trackers:
                    time.sleep(30)
                    continue

        if now - last_login > LOGIN_INTERVAL:
            if api_reachable():
                last_login = now
            elif login():
                last_login = now
            else:
                log("qbit unreachable and login failed; retrying")
                time.sleep(30)
                continue

        for t in get("/api/v2/torrents/info"):
            h = t["hash"]
            current = get(f"/api/v2/torrents/trackers?hash={h}")
            real = [tr for tr in current if not tr["url"].startswith("**")]
            if not real:
                log(f"injecting trackers into {h[:8]} — {t.get('name', '?')[:60]}")
                post("/api/v2/torrents/addTrackers", {"hash": h, "urls": "\n".join(trackers)})
                post("/api/v2/torrents/reannounce", {"hashes": h})

    except Exception as e:
        log(f"loop error: {e}")
        last_login = 0  # force re-login next iteration

    time.sleep(CHECK_INTERVAL)
