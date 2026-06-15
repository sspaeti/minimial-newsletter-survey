HOST       ?= ti
SSH        := ssh $(HOST)
SRC_DIR    := /home/sspaeti/survey-src
BIN        := /usr/local/bin/survey
DUCKDB_VER ?= 1.5.3

# duckdb_use_lib dynamically links against the system libduckdb (1.5.3) on the
# FreeBSD host, since duckdb-go's v2 bindings ship pre-built libs for darwin/
# linux/windows only.
BUILD_FLAGS := -tags=duckdb_use_lib

.PHONY: test fmt vet sync build deploy logs status query token duckdb-connect push-installer install-on-server smoke help \
        railway-token railway-docker-build railway-docker-run railway-duckdb-connect survey-result

SURVEY_HOST ?= survey.sspaeti.duckdns.org
QUACK_HOST  ?= quack.sspaeti.duckdns.org

help:
	@echo "Laptop targets (run on Arch):"
	@echo "  push-installer    - rsync source + installer to $(HOST):$(SRC_DIR)/,"
	@echo "                      then print the next-steps for the manual root install."
	@echo "  sync              - rsync source to $(HOST)"
	@echo "  build             - sync, then build Go binary on $(HOST)"
	@echo "  deploy            - build, then atomically swap binary and restart service"
	@echo "  logs              - tail service log on $(HOST)"
	@echo "  status            - show service status on $(HOST)"
	@echo "  query             - print the Quack ATTACH snippet to paste into duckdb"
	@echo "  token             - print the Quack token (reads from \$$HOST as root)"
	@echo "  duckdb-connect    - open local duckdb with the remote DB attached as 's'"
	@echo "                      (needs \$$SURVEY_QUACK_TOKEN env var)"
	@echo "  smoke             - end-to-end check (DNS + TLS + /healthz + HEAD /survey)"
	@echo "  test / fmt / vet  - local Go targets"
	@echo ""
	@echo "Railway targets (see docs/install-railway.md):"
	@echo "  railway-token            - print a fresh SURVEY_QUACK_TOKEN to paste into Railway env"
	@echo "  railway-docker-build     - docker build the Railway image locally for testing"
	@echo "  railway-docker-run       - docker run the image with a tmp volume + generated token"
	@echo "  railway-duckdb-connect   - duckdb attached to Railway's TCP Proxy"
	@echo "                             (needs RAILWAY_QUACK_HOST, RAILWAY_QUACK_PORT,"
	@echo "                              SURVEY_QUACK_TOKEN env vars)"
	@echo "  survey-result            - one-shot tally with bar chart of all surveys"
	@echo "                             (same env vars as railway-duckdb-connect)"
	@echo "                             pass SURVEY_ID=<id> for a single-survey detail view"
	@echo ""
	@echo "Server target (run on FreeBSD as root, after 'ssh $(HOST)' && 'su root'):"
	@echo "  install-on-server - one-shot setup: pkg deps, DuckDB $(DUCKDB_VER) build,"
	@echo "                      user/dirs, env+token, rc.d, sudoers. Idempotent."
	@echo "                      TLS terminates on your existing reverse proxy, not"
	@echo "                      Caddy. Add two NPM hosts:"
	@echo "                        survey.sspaeti.duckdns.org -> http://<ti-LAN-ip>:8080"
	@echo "                        quack.sspaeti.duckdns.org  -> http://<ti-LAN-ip>:9494"

push-installer: sync
	@echo ""
	@echo "==> Installer pushed to $(HOST):$(SRC_DIR)/"
	@echo ""
	@echo "Now run, in this order:"
	@echo "  ssh $(HOST)"
	@echo "  su root                            # enter root password"
	@echo "  cd $(SRC_DIR)"
	@echo "  make install-on-server             # ~20 min first time (DuckDB build)"
	@echo "  exit                               # leave root"
	@echo "  exit                               # leave ssh"
	@echo ""
	@echo "Then back here: make deploy"

install-on-server:
	@if [ "$$(id -u)" -ne 0 ]; then \
	    echo "error: install-on-server must run as root on the FreeBSD host." >&2; \
	    echo "       Do: ssh $(HOST), then 'su root', then 'cd $(SRC_DIR) && make install-on-server'." >&2; \
	    exit 1; \
	fi
	DUCKDB_VER=$(DUCKDB_VER) sh deploy/install-on-server.sh

test:
	go test ./...

fmt:
	gofmt -w .

vet:
	go vet ./...

sync:
	rsync -az --delete \
	  --exclude build/ --exclude .git/ --exclude docs/ --exclude .DS_Store \
	  ./ $(HOST):$(SRC_DIR)/

build: sync
	$(SSH) "cd $(SRC_DIR) && \
	        CGO_CFLAGS='-I/usr/local/include' \
	        CGO_LDFLAGS='-L/usr/local/lib -lduckdb' \
	        go build $(BUILD_FLAGS) -o build/survey ./cmd/survey"

deploy: build
	$(SSH) "sudo /bin/cp $(SRC_DIR)/build/survey $(BIN).new && \
	        sudo /bin/mv $(BIN).new $(BIN) && \
	        sudo /usr/sbin/service survey restart"

logs:
	$(SSH) "sudo /usr/bin/tail -f /var/log/survey/survey.log"

status:
	$(SSH) "sudo /usr/sbin/service survey status"

query:
	@echo "Paste into duckdb on your laptop:"
	@echo ""
	@echo "  CREATE SECRET (TYPE quack, TOKEN '<token from /usr/local/etc/survey/survey.env>');"
	@echo "  ATTACH 'quack:$(QUACK_HOST)' AS s;"
	@echo "  FROM s.votes ORDER BY ts DESC LIMIT 20;"

# Print the Quack token from the server. Use as:
#   export SURVEY_QUACK_TOKEN=$(make -s token)
token:
	@$(SSH) "sudo /usr/bin/cat /usr/local/etc/survey/survey.env" \
	    | awk -F= '/^SURVEY_QUACK_TOKEN=/{sub(/^SURVEY_QUACK_TOKEN=/,""); print}'

# Open duckdb locally with the remote Quack DB already attached as `s`.
# Token comes from the SURVEY_QUACK_TOKEN env var; the SQL goes through an
# mktemp init file (0600) so the token never appears in argv / ps output.
duckdb-connect:
	@command -v duckdb >/dev/null || { echo "error: duckdb CLI not on PATH (install duckdb locally first)" >&2; exit 1; }
	@if [ -z "$$SURVEY_QUACK_TOKEN" ]; then \
	    echo "error: SURVEY_QUACK_TOKEN not set" >&2; \
	    echo "       export SURVEY_QUACK_TOKEN=\$$(make -s token)" >&2; \
	    exit 1; \
	fi
	@tmp=$$(mktemp) && trap "rm -f $$tmp" EXIT INT TERM HUP && \
	  printf "INSTALL quack;\nLOAD quack;\nATTACH 'quack:%s' AS s (TOKEN '%s');\n" \
	    "$(QUACK_HOST)" "$$SURVEY_QUACK_TOKEN" > "$$tmp" && \
	  echo "" && \
	  echo "Connected. Try:  FROM s.votes ORDER BY ts DESC LIMIT 10;" && \
	  echo "" && \
	  duckdb -init "$$tmp"

# End-to-end smoke test from the laptop. Uses HEAD on /survey/* (server returns
# 200 without recording — anti-prefetch behavior), so no vote is created.
smoke:
	@set -e; \
	pass=0; fail=0; \
	check() { name="$$1"; shift; \
	    if out=$$("$$@" 2>&1); then echo "  PASS  $$name"; pass=$$((pass+1)); \
	    else echo "  FAIL  $$name: $$out"; fail=$$((fail+1)); fi; }; \
	echo "DNS"; \
	check "$(SURVEY_HOST) resolves" sh -c 'dig +short $(SURVEY_HOST) | grep -E "^[0-9]+\."'; \
	check "$(QUACK_HOST) resolves"  sh -c 'dig +short $(QUACK_HOST)  | grep -E "^[0-9]+\."'; \
	echo "HTTPS (NPM + cert)"; \
	check "$(SURVEY_HOST) TLS OK"   sh -c 'curl -sf --max-time 8 -o /dev/null -w "%{http_code}" https://$(SURVEY_HOST)/healthz | grep -E "^(200|502|404)$$"'; \
	check "$(QUACK_HOST) TLS OK"    sh -c 'curl -s  --max-time 8 -o /dev/null -w "%{http_code}" https://$(QUACK_HOST)/        | grep -E "^[2-5][0-9][0-9]$$"'; \
	echo "Survey service"; \
	check "/healthz returns 200"    sh -c '[ "$$(curl -s --max-time 8 -o /dev/null -w "%{http_code}" https://$(SURVEY_HOST)/healthz)" = "200" ]'; \
	check "HEAD /survey returns 200 (no vote recorded)" \
	                                sh -c '[ "$$(curl -sI --max-time 8 -o /dev/null -w "%{http_code}" https://$(SURVEY_HOST)/survey/_smoke/test)" = "200" ]'; \
	check "/thanks returns 200"     sh -c '[ "$$(curl -s --max-time 8 -o /dev/null -w "%{http_code}" https://$(SURVEY_HOST)/thanks)" = "200" ]'; \
	echo ""; \
	echo "$$pass passed, $$fail failed"; \
	[ "$$fail" = "0" ]

# --- Railway -------------------------------------------------------------
# See docs/install-railway.md for the full one-time setup.

RAILWAY_IMAGE ?= survey:railway

railway-token:
	@head -c 32 /dev/urandom | base64 | tr -d '\n'; echo

railway-docker-build:
	docker build -f deploy/railway/Dockerfile -t $(RAILWAY_IMAGE) .

railway-docker-run:
	@token=$$(head -c 32 /dev/urandom | base64 | tr -d '\n'); \
	echo "Generated SURVEY_QUACK_TOKEN (one-shot): $$token"; \
	docker run --rm -it \
	    -p 8080:8080 -p 9494:9494 \
	    -e SURVEY_HTTP_ADDR=0.0.0.0:8080 \
	    -e SURVEY_QUACK_ADDR=0.0.0.0:9494 \
	    -e SURVEY_QUACK_TOKEN="$$token" \
	    -v survey-data:/var/db/survey \
	    $(RAILWAY_IMAGE)

# Open local duckdb with helpers pre-defined for the remote Quack server.
#
# ATTACH 'quack:...' is broken in the quack extension build shipped with
# DuckDB 1.5.3 (Binder Error: Catalog "x" does not exist on a fresh ATTACH).
# quack_query() works fine, so we wrap it in a macro + view:
#
#   FROM remote_votes;                          -- whole table
#   FROM rq('SELECT survey_id, count(*)         -- arbitrary remote SQL
#           FROM votes GROUP BY ALL');
#
# Each call fetches a fresh snapshot from the server. Fine for the vote
# volumes this app handles.
railway-duckdb-connect:
	@command -v duckdb >/dev/null || { echo "error: duckdb CLI not on PATH (install duckdb locally first)" >&2; exit 1; }
	@if [ -z "$$SURVEY_QUACK_TOKEN" ] || [ -z "$$RAILWAY_QUACK_HOST" ] || [ -z "$$RAILWAY_QUACK_PORT" ]; then \
	    echo "error: need SURVEY_QUACK_TOKEN, RAILWAY_QUACK_HOST, RAILWAY_QUACK_PORT" >&2; \
	    echo "       see docs/install-railway.md" >&2; \
	    exit 1; \
	fi
	@tmp=$$(mktemp) && trap "rm -f $$tmp" EXIT INT TERM HUP && \
	  printf "INSTALL quack;\nLOAD quack;\nCREATE OR REPLACE MACRO rq(sql) AS TABLE (FROM quack_query('quack:%s:%s', sql, token => '%s', disable_ssl => true));\nCREATE OR REPLACE VIEW remote_votes AS FROM rq('FROM votes');\n" \
	    "$$RAILWAY_QUACK_HOST" "$$RAILWAY_QUACK_PORT" "$$SURVEY_QUACK_TOKEN" > "$$tmp" && \
	  echo "" && \
	  echo "Connected via quack_query (ATTACH is broken in quack 1.5.3)." && \
	  echo "Try:" && \
	  echo "  FROM remote_votes;" && \
	  echo "  FROM remote_votes WHERE survey_id = '2026-06-04';" && \
	  echo "  FROM rq('SELECT survey_id, answer, count(*) FROM votes GROUP BY ALL');" && \
	  echo "" && \
	  duckdb -init "$$tmp"

# One-shot tally with ascii bar chart.
#
#   make survey-result                          # all surveys, bars relative to each survey's top answer
#   make survey-result SURVEY_ID=2026-06-04     # one survey only, bars relative to its top answer
#
# Same env vars as railway-duckdb-connect: SURVEY_QUACK_TOKEN,
# RAILWAY_QUACK_HOST, RAILWAY_QUACK_PORT. SURVEY_ID is validated against the
# same slug regex the server uses, so we can interpolate it safely.
SURVEY_ID ?=

survey-result:
	@command -v duckdb >/dev/null || { echo "error: duckdb CLI not on PATH (install duckdb locally first)" >&2; exit 1; }
	@if [ -z "$$SURVEY_QUACK_TOKEN" ] || [ -z "$$RAILWAY_QUACK_HOST" ] || [ -z "$$RAILWAY_QUACK_PORT" ]; then \
	    echo "error: need SURVEY_QUACK_TOKEN, RAILWAY_QUACK_HOST, RAILWAY_QUACK_PORT" >&2; \
	    echo "       see docs/install-railway.md" >&2; \
	    exit 1; \
	fi
	@if [ -n "$(SURVEY_ID)" ] && ! echo "$(SURVEY_ID)" | grep -qE '^[a-z0-9][a-z0-9_-]{0,63}$$'; then \
	    echo "error: SURVEY_ID must match ^[a-z0-9][a-z0-9_-]{0,63}\$$" >&2; \
	    exit 1; \
	fi
	@tmp=$$(mktemp) && trap "rm -f $$tmp" EXIT INT TERM HUP && \
	  printf "INSTALL quack;\nLOAD quack;\nCREATE OR REPLACE MACRO rq(sql) AS TABLE (FROM quack_query('quack:%s:%s', sql, token => '%s', disable_ssl => true));\nCREATE OR REPLACE VIEW remote_votes AS FROM rq('FROM votes');\n" \
	    "$$RAILWAY_QUACK_HOST" "$$RAILWAY_QUACK_PORT" "$$SURVEY_QUACK_TOKEN" > "$$tmp" && \
	  if [ -n "$(SURVEY_ID)" ]; then \
	    duckdb -init "$$tmp" -c "WITH t AS (SELECT answer, count(*) AS clicks FROM remote_votes WHERE survey_id = '$(SURVEY_ID)' GROUP BY answer) SELECT '$(SURVEY_ID)' AS survey_id, answer, clicks, bar(clicks, 0, (SELECT max(clicks) FROM t), 30) AS chart FROM t ORDER BY clicks DESC;"; \
	  else \
	    duckdb -init "$$tmp" -c "WITH t AS (SELECT survey_id, answer, count(*) AS clicks FROM remote_votes GROUP BY ALL), m AS (SELECT survey_id, max(clicks) AS top FROM t GROUP BY survey_id) SELECT t.survey_id, t.answer, t.clicks, bar(t.clicks, 0, m.top, 30) AS chart FROM t JOIN m USING (survey_id) ORDER BY t.survey_id DESC, t.clicks DESC;"; \
	  fi
