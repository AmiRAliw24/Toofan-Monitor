# Defender agent: only the tools it drives. Its Python code is mounted from ./defender, so updating
# the code needs a restart, not a rebuild.
FROM python:3.12-alpine
RUN apk add --no-cache nftables conntrack-tools iproute2 util-linux-misc
ENV PYTHONDONTWRITEBYTECODE=1
CMD ["python", "-u", "/app/agent.py"]
