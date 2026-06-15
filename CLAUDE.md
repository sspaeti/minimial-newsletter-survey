# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A ~200-line Go HTTP service that records anonymous newsletter-rating clicks into a DuckDB file and exposes that file remotely via the DuckDB Quack extension so queries can run from a laptop. Design doc: `docs/superpowers/specs/2026-06-04-newsletter-survey-design.md`.

## Common commands

Local dev (laptop):

```sh
make test          # go test ./...
make fmt           # gofmt -w .
make vet           # go vet ./...
go test ./internal/voter -run TestHash   # single test (standard go test usage)
```

Deploy targets all act on remote host `$HOST` (default `ti`, a FreeBSD box) over SSH:

```sh
make sync                  # rsync source → $HOST:/home/sspaeti/survey-src
make build                 # sync + go build on the host with -tags=duckdb_use_lib
make deploy                # build + atomic binary swap + service restart
make logs / make status    # tail / status of the survey service
make smoke                 # DNS + TLS + /healthz end-to-end check
make token                 # print SURVEY_QUACK_TOKEN read from the server
make duckdb-connect        # open local duckdb CLI with remote DB attached as `s`
make push-installer        # rsync, then prints next steps for one-time root install
```

`make install-on-server` only runs as root on the FreeBSD host (after `ssh ti && su root`) — it is not for laptop use.

## Architecture — what requires reading multiple files

**Three small packages glued by `cmd/survey/main.go`:**

- `internal/server` — single mux with `/survey/{id}/{answer}`, `/thanks`, `/healthz`. Both slugs validated against `^[a-z0-9][a-z0-9_-]{0,63}$`. `HEAD /survey/*` returns 200 without recording, to defeat Gmail/Microsoft Safe Links prefetch. `clientIP` reads the first hop of `X-Forwarded-For` (set by the external reverse proxy) and falls back to `RemoteAddr`. `thanks.html` is `embed.FS`-included.
- `internal/store` — opens DuckDB with `MaxOpenConns(1)` (DuckDB has a single writer; pinning ensures the in-process `quack_serve` shares the session). Schema is one `votes` table keyed by `(survey_id, voter)` so re-votes upsert (last vote wins). After schema, it runs `INSTALL quack; LOAD quack; CALL quack_serve(...)` — this binds a second port and is what makes the laptop's `ATTACH 'quack:...'` work. The token is interpolated into SQL (the Go driver doesn't bind named params); `tokenSafe` regex defends.
- `internal/voter` — per-process 32-byte salt, regenerated at startup and rotated lazily at UTC midnight on first read after the day flips. `Hash(ip, ua, surveyID, salt)` returns the first 16 bytes of SHA-256 hex. Including `survey_id` in the hash means the same reader hashes differently across newsletters, blocking cross-issue tracking. The salt is never persisted — past hashes cannot be reproduced after rotation.

**Two listening ports, one process:** HTTP on `SURVEY_HTTP_ADDR` (default `127.0.0.1:8080`) for click traffic; Quack on `SURVEY_QUACK_ADDR` (default `127.0.0.1:9494`) opened by DuckDB itself via `quack_serve`. TLS terminates externally on a reverse proxy (Nginx Proxy Manager).

**Env required:** `SURVEY_QUACK_TOKEN` (URL-safe base64). Optional: `SURVEY_DB_PATH`, `SURVEY_HTTP_ADDR`, `SURVEY_QUACK_ADDR`, `SURVEY_BLOG_URL`.

## Platform / build notes

- DuckDB Go bindings ship prebuilt `libduckdb` for darwin/linux/windows. **FreeBSD is not in that list** — the `Makefile` adds `-tags=duckdb_use_lib` plus `CGO_CFLAGS`/`CGO_LDFLAGS` for `/usr/local/include` and `/usr/local/lib` to dynamically link against the system `libduckdb.so` built from source by `deploy/install-on-server.sh`. Linux builds need no tag.
- `.github/workflows/build-freebsd-libduckdb.yml` is a backup path for fetching a prebuilt FreeBSD `libduckdb`; the installer normally builds it locally (~20 min first run).

## Conventions worth keeping

- Slug regex is the only input gate on URL params — don't relax it without thinking about what ends up as a `votes` row.
- The token must remain URL-safe-base64-shaped because it goes into a `CALL quack_serve('...')` string (`tokenSafe` in `store.go`). Don't switch to a different alphabet without re-quoting.
- IP and User-Agent are read per request, fed to the hash, and dropped. Don't add logging of either; the only logged fields are `survey_id` and `answer`.
