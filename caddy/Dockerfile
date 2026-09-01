# Caddy with the two modules this setup needs, neither of which ships in the
# stock image:
#
#   caddy-ratelimit          - stock Caddy has NO rate limiting at all, and the
#                              Jellyfin login endpoint is the thing most worth
#                              protecting once this is public.
#   caddy-crowdsec-bouncer   - lets Caddy drop traffic CrowdSec has flagged,
#                              before it ever reaches Jellyfin.
#
# Both require compiling Caddy from source via xcaddy. That's why this is a
# build rather than an image reference.

ARG CADDY_VERSION=2

FROM caddy:${CADDY_VERSION}-builder-alpine AS builder

RUN xcaddy build \
    --with github.com/mholt/caddy-ratelimit \
    --with github.com/hslatman/caddy-crowdsec-bouncer/http@main

FROM caddy:${CADDY_VERSION}-alpine

COPY --from=builder /usr/bin/caddy /usr/bin/caddy

# Caddy writes access logs here; CrowdSec reads them (see crowdsec/acquis.yaml)
RUN mkdir -p /var/log/caddy
