# minimal-newsletter-survey

A ~200-line Go service that records anonymous reader ratings from newsletter
links into a [DuckDB](https://ssp.sh/brain/duckdb) file. Per-newsletter, per-answer, no cookies, no JS.
Query the results from your laptop over Quack.

Design doc: [`docs/superpowers/specs/2026-06-04-newsletter-survey-design.md`](docs/superpowers/specs/2026-06-04-newsletter-survey-design.md).

## What it looks like in a newsletter

```markdown
What did you think of today's newsletter?

[Awesome!](https://survey.sspaeti.duckdns.org/survey/2026-06-04/awesome)
[Pretty Good](https://survey.sspaeti.duckdns.org/survey/2026-06-04/good)
[Could be better](https://survey.sspaeti.duckdns.org/survey/2026-06-04/better)
```

Each click records one vote and redirects to a "Thanks!" page. The next
newsletter can use entirely different `survey_id` and `answer` slugs without
any code or schema change.

## How votes are deduplicated

`voter = sha256(ip || ua || daily_salt || survey_id)[:16]` (hex).

- The daily salt is 32 random bytes generated in memory at startup, rotated
  every midnight UTC, and regenerated on every process restart. It is
  **never written to disk**.
- After rotation, yesterday's hashes can no longer be reproduced from logs.
- Including `survey_id` in the hash means the same reader produces different
  hashes for different newsletters, so cross-issue tracking is impossible.

If the same reader clicks twice on the same newsletter (e.g. Awesome, then
Good), the second click replaces the first — last vote wins.

## One-time server setup

The server needs Go, a `libduckdb` available to the linker (or a built-in
one via the Go bindings on Linux), an env file with a generated Quack
token, and a service supervisor. Pick your platform:

- **[Railway](docs/install-railway.md)** — Docker-based, one service,
  persistent volume for the DuckDB file. HTTP on Railway's HTTPS edge,
  Quack exposed via TCP Proxy so you can `ATTACH` from your laptop without
  custom DNS up front.
- **[Linux (EC2 / Hetzner / anywhere)](docs/install-linux.md)** — much
  shorter. `duckdb-go-bindings/v2` ships a prebuilt `libduckdb` for Linux,
  so `go build` Just Works. ~10 lines of shell + a systemd unit.
- **[FreeBSD](docs/install-freebsd.md)** — what I actually run on `ti`.
  Needs a from-source DuckDB build (~20 min) because upstream ships no
  FreeBSD binaries. Automated via `make push-installer` → `make install-on-server`.

> [!NOTE]
> FreeBSD because I already have one running on my self-hosted server, so it
> costs me nothing extra. If I were starting fresh, EC2 with the Linux guide
> would be ~$3-7/mo and would skip the source build entirely.

## Reverse proxy + TLS (external)

TLS termination happens on whatever reverse proxy is in front of `ti`
(e.g. Nginx Proxy Manager on Unraid). Add two proxy hosts with Let's Encrypt:

| Hostname                       | Backend                         |
|--------------------------------|---------------------------------|
| `survey.sspaeti.duckdns.org`   | `http://<ti-LAN-ip>:8080`       |
| `quack.sspaeti.duckdns.org`    | `http://<ti-LAN-ip>:9494`       |

The `survey.*` host carries the click traffic; the `quack.*` host carries
the DuckDB Quack remote-protocol traffic for ad-hoc queries from your laptop.
Restrict the two ports to LAN-only on `ti`'s firewall — they shouldn't be
reachable from the public internet directly.

## Deploy

From your laptop, in this directory:

```sh
make deploy
```

This rsyncs the source to the host, builds the Go binary there, atomically
swaps `/usr/local/bin/survey`, and restarts the service. On FreeBSD the build
links dynamically against the system `libduckdb.so` via `-tags=duckdb_use_lib`;
on Linux the prebuilt library inside `duckdb-go-bindings/v2` is used and no
extra tag is needed.

Run `make help` for the full target list. Common ones:
`make smoke` (DNS + TLS + healthz), `make logs`, `make status`,
`make token`, `make duckdb-connect`.

## Query from your laptop

Fastest path:

```sh
export SURVEY_QUACK_TOKEN=$(make -s token)    # one-time, fetches over SSH
make duckdb-connect                            # opens duckdb with `s` attached
```

Then:

```sql
-- One newsletter's results
FROM s.votes
WHERE survey_id = '2026-06-04'
GROUP BY answer
ORDER BY count(*) DESC;

-- All-time rolling tally
SELECT survey_id, answer, count(*) AS votes
FROM s.votes
GROUP BY ALL
ORDER BY survey_id DESC, votes DESC;
```

Or paste manually:

```sql
CREATE SECRET (TYPE quack, TOKEN '<paste your token>');
ATTACH 'quack:quack.sspaeti.duckdns.org' AS s;
FROM s.votes ORDER BY ts DESC LIMIT 20;
```

Fallback if Quack misbehaves: `ssh ti "duckdb /var/db/survey/votes.duckdb -c 'FROM votes'"`.

## Privacy

- No cookies, no JavaScript, no fingerprinting.
- IP and User-Agent are read on each request, fed into the voter hash, and
  immediately discarded. Nothing identifying is persisted.
- The daily salt rotation means past hashes cannot be reproduced — even with
  access to server logs.
- Access logs record only `survey_id` and `answer`.

## Layout

```
.
├── cmd/survey/main.go             # entrypoint, env wiring
├── internal/
│   ├── server/server.go           # routes, click handler, X-Forwarded-For
│   ├── server/thanks.html         # embedded thanks page
│   ├── store/store.go             # DuckDB open, schema, quack_serve, upsert
│   └── voter/hash.go              # daily salt + voter hash
├── deploy/
│   ├── install-on-server.sh       # idempotent FreeBSD installer (runs as root on ti)
│   ├── survey.rc                  # FreeBSD rc.d service script
│   └── survey.env.example         # env-var template
├── docs/
│   ├── install-linux.md           # minimal Linux/EC2 guide (the easy path)
│   └── install-freebsd.md         # full FreeBSD guide (what this repo's installer automates)
├── Makefile
└── go.mod
```
