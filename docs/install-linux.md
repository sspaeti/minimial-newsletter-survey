# Linux install (EC2, DO, Hetzner, anywhere)


> [!WARNING]
> This setup is not tested, I use the FreeBSD one, but should work as Hannes [showcases it here](https://www.youtube.com/live/ACOMAyOEFYU?si=7jkGNaNgm_WQ7CbN&t=2228), too.

Much simpler than the FreeBSD path because:

- `duckdb-go-bindings/v2` ships **prebuilt `libduckdb` for Linux x86_64 and
  arm64**. You don't need to build DuckDB from source. `go build` Just Works.
- `systemd` is universal; no rc.d service script needed.
- `sudo` is usually pre-configured.
- DuckDB CLI is one curl: `curl https://install.duckdb.org | sh` (if you want
  it on the server for fallback queries).

This guide is an outline, not a one-shot installer. Adapt to your distro
(`apt`, `dnf`, etc.).

## Provision

Any small VM works. Click volume is ~4000 subs × ~10% CTR = a few hundred
requests per newsletter. Realistic sizes:

- **EC2 t4g.nano** (~$3/mo, ARM) — fine
- **EC2 t4g.small** (~$12/mo) if you want headroom
- **Hetzner CAX11** (~€4/mo, ARM) — also fine
- **Fly.io** machine, **Railway**, etc. — same workload, similar cost

## Install

```sh
# As root (or via sudo). Replace apt with your distro's package manager.
apt update
apt install -y golang git make rsync

# Service user + dirs (matches what the FreeBSD installer does)
useradd --system --no-create-home --shell /usr/sbin/nologin survey
mkdir -p /var/db/survey /var/log/survey /etc/survey
chown survey:survey /var/db/survey /var/log/survey

# Source
git clone <this-repo> /opt/survey-src
cd /opt/survey-src
go build -o /usr/local/bin/survey ./cmd/survey
chmod +x /usr/local/bin/survey

# Env file with a fresh token
TOKEN=$(head -c 32 /dev/urandom | base64 | tr -d '\n')
cat > /etc/survey/survey.env <<EOF
SURVEY_DB_PATH=/var/db/survey/votes.duckdb
SURVEY_HTTP_ADDR=0.0.0.0:8080
SURVEY_QUACK_ADDR=0.0.0.0:9494
SURVEY_BLOG_URL=https://www.ssp.sh
SURVEY_QUACK_TOKEN=${TOKEN}
EOF
chmod 0600 /etc/survey/survey.env
chown survey:survey /etc/survey/survey.env
echo "Quack token (save this): ${TOKEN}"
```

## systemd unit

`/etc/systemd/system/survey.service`:

```ini
[Unit]
Description=minimal newsletter survey
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=survey
Group=survey
EnvironmentFile=/etc/survey/survey.env
ExecStart=/usr/local/bin/survey
Restart=on-failure
RestartSec=2s

# Hardening
ProtectSystem=strict
ProtectHome=true
ReadWritePaths=/var/db/survey /var/log/survey
NoNewPrivileges=true
PrivateTmp=true

[Install]
WantedBy=multi-user.target
```

Then:

```sh
systemctl daemon-reload
systemctl enable --now survey
journalctl -u survey -f
```

## Reverse proxy

Same as the [main README](../README.md#reverse-proxy--tls-external) — point
your reverse proxy (Caddy, nginx, NPM, Traefik, anything) at:

- `survey.<your-domain>` → `http://<vm-ip>:8080`
- `quack.<your-domain>`  → `http://<vm-ip>:9494`

If you don't already have a reverse proxy, **Caddy is the lowest-friction
option** because it does Let's Encrypt automatically with zero config:

```
survey.example.com {
    reverse_proxy 127.0.0.1:8080
}
quack.example.com {
    reverse_proxy 127.0.0.1:9494
}
```

## Going forward: deploy updates

The `Makefile`'s `deploy` target assumes a FreeBSD layout
(`/home/sspaeti/survey-src`, `doas`/`sudo` swap of the binary at
`/usr/local/bin/survey`). On Linux you can do the same flow trivially —
rsync source, `go build`, `systemctl restart survey` — but adapt the paths
to wherever you put things.
