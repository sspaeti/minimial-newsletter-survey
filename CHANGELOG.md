# Changelog

All notable changes to this project are listed here. Format loosely
follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/); the
project does not yet ship versioned releases, so changes are grouped by
date instead.


## 2026-06-16
- **`make survey-create SURVEY_ID=… ANSWERS=a,b,c`** — register a survey's
  allowed answer slugs. Writes through Quack with `ON CONFLICT DO UPDATE`
  so re-running upserts. Unregistered surveys stay in open mode (current
    - **`surveys` table** in the schema:
      `survey_id PRIMARY KEY, allowed_answers VARCHAR, created_at TIMESTAMP`.
      Populated by `make survey-create`; checked per-vote by
      `store.GetAllowedAnswers`. Missing row = open mode; row present =
      only listed answers count, rest get `answer-reject` log.
      default behaviour).
- **OG / Twitter social-card meta tags** on `/result/{survey_id}`, backed by
  a generic embedded banner served at `/og-image.png` (so previews don't lie
  about specific vote counts). Absolute URLs derived from `X-Forwarded-Proto`
  + `Host` per request.

## 2026-06-15 Railway, short URLs, per-survey answer locking

A big batch — Railway deployment path, URL-shape change, server-rendered
result page, CSS extraction, bot filtering, and per-survey answer
allowlist. The repo was also renamed to **pollmd** during this work.

### Added

- **Railway deployment path.** New `deploy/railway/Dockerfile` (multi-stage,
  `golang:1.24-bookworm` → `debian:bookworm-slim` runtime), root-level
  `railway.json` (auto-detected by Railway), root `.dockerignore`, and
  `docs/install-railway.md` with the one-time setup walkthrough — service
  creation, volume mount at `/var/db/survey`, env vars, TCP Proxy for
  Quack on port 9494.
- **Railway Makefile targets:** `railway-token`, `railway-docker-build`,
  `railway-docker-run`, `railway-duckdb-connect`.
- **Short URL shape.** Primary vote URL is now
  `https://q.ssp.sh/{survey_id}/{answer}` (drops the `/survey/` segment).
  Built on Go 1.22+ `ServeMux` pattern matching with
  `r.PathValue("id")` / `r.PathValue("answer")`. Route patterns live as
  constants at the top of `internal/server/server.go`.
- **Legacy URL alias.** `/survey/{id}/{answer}` still routes to the same
  handler so links shipped in past newsletters keep working.
- **Per-survey results page** at `/result/{survey_id}`. Server-rendered
  HTML bar chart driven by `store.TallyBySurvey`. No DuckDB-WASM, no
  query interface in the browser — knowing the slug is the access
  control. Marked `noindex`.
- **`internal/server/result.html`** template.
- **Shared CSS file** at `internal/server/style.css`, served from
  `/style.css` with `Cache-Control: public, max-age=3600`. Both templates
  `<link>` it instead of carrying inline `<style>` blocks.
- **Bot User-Agent filter** in the vote handler. Social-media unfurlers
  (Twitter, Bluesky, Slack, Discord, LinkedIn, …), search crawlers,
  headless link checkers, RSS readers, security scanners, and empty
  UAs all get 200-without-record. Logged as
  `bot-skip survey_id=… answer=…`. List lives in `botUASubstrings`.
- **`make survey-result` / `make survey-result SURVEY_ID=…`** — one-shot
  bar-chart tally over the remote DuckDB via `quack_query`. Non-interactive.
- **`make survey-reset SURVEY_ID=…`** — wipe every vote for one survey.
  Requires explicit `SURVEY_ID`, prompts to confirm
  (`CONFIRM=yes` to skip), uses `DELETE … RETURNING *` so deleted rows
  are printed.
- **`store.TallyBySurvey`** — per-answer count for a survey, ordered most
  popular first.
- **pollmd footer** on `/thanks` and `/result/{id}` — small grey
  "Created with pollmd" link to https://github.com/sspaeti/pollmd.

### Changed

- **`internal/store/store.go` schema** split into `schemaVotes` and
  `schemaSurveys`, run as separate `Exec` calls.
- **`make railway-duckdb-connect` rewritten** to use a `quack_query`
  macro (`rq(sql)`) + `remote_votes` view instead of
  `ATTACH 'quack:…'`. ATTACH-with-Quack is broken in the build shipped
  with DuckDB 1.5.3 (`extension_version 1693647`) — fresh ATTACH errors
  with `Binder Error: Catalog "x" does not exist!`. Swap back to ATTACH
  when the next Quack release lands.
- **`make duckdb-connect` / `railway-duckdb-connect`** SQL: dropped
  `FROM community`. Quack lives in the `core` extension repo from DuckDB
  1.5.3 onwards.
- **`ATTACH 'quack:…'`** in the client-side init file now passes
  `DISABLE_SSL true` because Railway TCP Proxy is plaintext (no TLS at
  this layer; the Quack token is the auth).
- **Railway Dockerfile** simplified — removed an entrypoint shell-script
  that derived `SURVEY_HTTP_ADDR` from Railway's `$PORT`. Image-level
  `ENV` now sets sensible defaults
  (`SURVEY_HTTP_ADDR=0.0.0.0:8080`, `SURVEY_QUACK_ADDR=0.0.0.0:9494`,
  `SURVEY_DB_PATH=/var/db/survey/votes.duckdb`).
- **Smoke test** now checks both the short and legacy path shapes,
  plus `/result/_smoke`.
- **README** restructured around the new short-URL flow and the
  per-survey answer-locking workflow.

### Fixed

- **`INSTALL quack FROM community`** → **`INSTALL quack`** in both server
  (`internal/store/store.go`) and Makefile init files. Quack moved to
  the `core` repo in DuckDB 1.5.3.
- **Railway healthcheck failing** with the simplified Dockerfile — fixed
  by setting `PORT=8080` in the Railway service env vars so Railway's
  internal healthcheck hits the same port the app actually binds.
- **`ATTACH 'quack:…' AS s` returning "Catalog s does not exist!"** —
  worked around by using `quack_query` exclusively in the Makefile
  targets and helper macros, since `quack_query` is fine on the same
  extension build.

### Removed

- **`SURVEY_ANSWERS` env var.** Added briefly as a global allowlist, then
  removed in favour of the per-survey `surveys` table. Env-var approach
  would have forced the same answer set across every newsletter, which
  defeats the per-issue flexibility this project is for.

### Privacy / behavioural notes

- IP and User-Agent are still read-only inputs to the voter hash, never
  persisted. Bot/answer-reject log lines record only `survey_id` and
  `answer` — same constraint as the original vote log.
- Daily-rotating in-memory salt unchanged. Past hashes still
  unreproducible after midnight UTC.
