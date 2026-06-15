# Railway install

Single Railway service, single container, both ports exposed:

- **HTTP** for newsletter clicks on Railway's auto-HTTPS edge (the `$PORT` envvar Railway assigns).
- **Quack** on port `9494` exposed via Railway's **TCP Proxy** so you can `ATTACH` from your laptop.

DuckDB has a single-writer constraint and `quack_serve` must run in the same process as the writer, so this can't be split into two services.

> [!NOTE]
> Until you wire a custom domain (step 2), the Quack TCP proxy is plaintext. The token still authenticates, but traffic is unencrypted in transit. Fine for a low-stakes vote DB; add a custom domain + Caddy/Nginx in front of Quack when you care.
>
> The laptop `ATTACH` therefore needs `DISABLE_SSL true` (the Quack client defaults to HTTPS for non-`localhost` URIs — see the [Quack overview](https://duckdb.org/docs/current/quack/overview.html)). `make railway-duckdb-connect` already passes that option.

## Version requirement

DuckDB **≥ 1.5.3** on both sides:

- **Server (Railway):** automatic. `go.mod` pins `duckdb-go-bindings/v2 v0.10503.x` which bundles libduckdb 1.5.3. The container also needs outbound HTTPS so `INSTALL quack` can fetch the extension from `extensions.duckdb.org` at startup — Railway gives you that by default.
- **Laptop:** install/upgrade to DuckDB 1.5.3+ (`curl https://install.duckdb.org | sh`). On 1.5.3 Quack lives in the `core` extension repo, so `INSTALL quack` works with no `FROM …` clause. Earlier versions had it under `core_nightly` and won't work with the Makefile targets.

## What's in this repo for Railway

```
deploy/railway/
├── Dockerfile       # multi-stage: golang:1.24-bookworm → debian:bookworm-slim
└── railway.json     # tells Railway: use Dockerfile builder, /healthz healthcheck

.dockerignore        # at repo root (Docker requires it there). Trims build context.
```

## One-time setup

### 1. Create the Railway service

From [railway.app](https://railway.app):

- **New Project** → **Deploy from GitHub repo** → pick this repo.
- Railway will detect `railway.json` at the repo root only. Since ours is at `deploy/railway/railway.json`, set it manually:
  - **Service → Settings → Config-as-Code → Config Path:** `deploy/railway/railway.json`
- Alternatively, skip the config file and set in the dashboard:
  - **Settings → Source → Root Directory:** `.`
  - **Settings → Build → Builder:** `Dockerfile`
  - **Settings → Build → Dockerfile Path:** `deploy/railway/Dockerfile`
  - **Settings → Deploy → Healthcheck Path:** `/healthz`

### 2. Attach a persistent volume

Without this, every redeploy wipes the votes.

- **Service → Settings → Volumes → New Volume**
- **Mount path:** `/var/db/survey`
- Size: 1 GB is wildly overkill but fine.

### 3. Generate the Quack token

```sh
make railway-token
```

Copy the output — you'll paste it into env vars next.

### 4. Set environment variables

**Service → Variables**:

| Name                  | Value                              |
|-----------------------|------------------------------------|
| `SURVEY_HTTP_ADDR`    | `0.0.0.0:${{PORT}}`                |
| `SURVEY_QUACK_ADDR`   | `0.0.0.0:9494`                     |
| `SURVEY_QUACK_TOKEN`  | *(paste token from step 3)*        |
| `SURVEY_DB_PATH`      | `/var/db/survey/votes.duckdb`      |
| `SURVEY_BLOG_URL`     | `https://www.ssp.sh`               |

`${{PORT}}` is Railway's variable-reference syntax — it expands to whatever Railway assigns at runtime. Don't hard-code `8080`.

### 5. Expose the Quack port via TCP Proxy

- **Service → Settings → Networking → TCP Proxy → +Add**
- **Application Port:** `9494`
- Railway will return something like `tcp-proxy.proxy.rlwy.net:38712`. Save those two values — you need them to `ATTACH` from your laptop.

While you're there, confirm the **Public Networking** entry was auto-created for HTTP. It'll be `<service>.up.railway.app`.

### 6. Deploy

```sh
# Push the branch with deploy/railway/ + .dockerignore to GitHub. Railway
# auto-deploys on push to the configured branch.
git push
```

Or trigger from the dashboard: **Deployments → Redeploy**.

First build takes ~2-4 min (Go compile + libduckdb extraction). Watch logs for:

```
survey: HTTP on 0.0.0.0:8080, Quack on 0.0.0.0:9494
```

Healthcheck on `/healthz` should turn green within ~30s after that.

## Query from your laptop

```sh
export SURVEY_QUACK_TOKEN='<paste the token>'
export RAILWAY_QUACK_HOST='tcp-proxy.proxy.rlwy.net'
export RAILWAY_QUACK_PORT='38712'                    # from step 5

make railway-duckdb-connect
```

Then:

```sql
FROM s.votes ORDER BY ts DESC LIMIT 20;

-- Tally per newsletter
SELECT survey_id, answer, count(*) AS votes
FROM s.votes
GROUP BY ALL
ORDER BY survey_id DESC, votes DESC;
```

## Smoke test the HTTP side

```sh
curl -s https://<your-service>.up.railway.app/healthz
# -> ok

curl -sI https://<your-service>.up.railway.app/survey/_smoke/test
# -> 200 (HEAD requests don't record a vote; anti-prefetch behaviour)
```

## Local Docker check (optional)

To verify the Dockerfile works before pushing:

```sh
make railway-docker-build
make railway-docker-run     # generates a one-shot token, mounts a tmp volume
# Then in another terminal:
curl http://localhost:8080/healthz
```

## Custom domain (step 2)

When you're ready to point real DNS at the service:

- **HTTP click traffic** — Service → Settings → Networking → Custom Domain → `survey.<your-domain>`. Railway handles cert provisioning automatically.
- **Quack** — TCP Proxy doesn't get a custom domain directly. Options:
  1. Front it with a separate small service (Caddy in a sidecar container or a separate Railway service that reverse-proxies to Railway's internal `tcp-proxy.proxy.rlwy.net:NNNNN`).
  2. Use the existing TCP Proxy hostname directly and accept plaintext-with-token (current setup).
  3. Move Quack to a custom-domain HTTP path via Caddy in this same container — would require deviating from the current "no sidecar" design.

For now the plaintext TCP Proxy is fine; the token is the actual auth.

## Going forward: updates

Railway auto-deploys on git push to the configured branch. There's no `make railway-deploy` — that target is intentionally absent. The existing `make deploy` still targets FreeBSD (`ti`) and is untouched.

If you need to query the DB directly inside the container (debug path):

```sh
# In the Railway dashboard, open the service shell.
duckdb /var/db/survey/votes.duckdb -c 'FROM votes ORDER BY ts DESC LIMIT 20'
```

(Container doesn't ship the duckdb CLI by default; install it on the fly if you want it: `apt update && apt install -y duckdb` won't work on Debian without the repo — easier to just exfiltrate via `make railway-duckdb-connect` from your laptop.)
