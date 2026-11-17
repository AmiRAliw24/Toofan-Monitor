# Defender agent: only the tools it drives. Its Python code is mounted from ./defender, so updating
# the code needs a restart, not a rebuild.
FROM python:3.12-alpine
# ALPINE_MIRROR: an Alpine package mirror for servers where Alpine's CDN is blocked (set by the installer)
ARG ALPINE_MIRROR=
RUN if [ -n "$ALPINE_MIRROR" ]; then sed -i "s#https\?://dl-cdn.alpinelinux.org/alpine#${ALPINE_MIRROR%/}#" /etc/apk/repositories; fi  && apk add --no-cache nftables conntrack-tools iproute2 util-linux-misc
ENV PYTHONDONTWRITEBYTECODE=1
CMD ["python", "-u", "/app/agent.py"]
