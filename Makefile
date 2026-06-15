HOST       ?= ti
SSH        := ssh $(HOST)
SRC_DIR    := /home/sspaeti/survey-src
BIN        := /usr/local/bin/survey
DUCKDB_VER ?= 1.5.3

# duckdb_use_lib dynamically links against the system libduckdb (1.5.3) on the
# FreeBSD host, since duckdb-go's v2 bindings ship pre-built libs for darwin/
# linux/windows only.
BUILD_FLAGS := -tags=duckdb_use_lib

.PHONY: test fmt vet sync build deploy logs status query token duckdb-connect push-installer install-on-server smoke help

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
	  printf "INSTALL quack FROM community;\nLOAD quack;\nATTACH 'quack:%s' AS s (TYPE QUACK, TOKEN '%s');\n.echo on\n.echo \"\\\\nConnected. Try:  FROM s.votes ORDER BY ts DESC LIMIT 10;\\\\n\"\n.echo off\n" "$(QUACK_HOST)" "$$SURVEY_QUACK_TOKEN" > "$$tmp" && \
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
