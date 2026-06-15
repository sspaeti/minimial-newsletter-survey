# FreeBSD install

This is the path I actually run on `ti.sspaeti.duckdns.org`. If you're starting
fresh on Linux, the [Linux guide](install-linux.md) is much shorter — FreeBSD
needs a source build of DuckDB because the upstream project ships no FreeBSD
binaries and `duckdb-go-bindings/v2` covers only darwin/linux/windows.

## Flow

The install needs root on the FreeBSD host. Because SSH non-TTY sessions
can't prompt for a sudo/doas password, the flow is split: laptop pushes the
files, then you SSH in interactively and run the install as root.

```sh
# 1. From your laptop:
make push-installer

# 2. Then on the FreeBSD host (the makefile output reminds you):
ssh ti
su root                        # enter root password
cd /home/sspaeti/survey-src
make install-on-server         # ~20 min first time (DuckDB build)
exit                           # leave root
exit                           # leave ssh
```

## What `make install-on-server` does

Idempotently, in this order:

1. Installs build deps via `pkg`: `go`, `rsync`, `git`, `cmake`, `ninja`,
   `gmake`, `python3`. Also runs `pkg upgrade` on those packages to heal
   stale dep skew (e.g. an installed `git` linked against an older
   `libpcre2` than what's now on disk — a real failure I hit).
2. Builds DuckDB from source under `/usr/local/src/duckdb-<ver>`, then installs
   under `/usr/local`. Skipped on reruns once `/usr/local/bin/duckdb` reports
   the right version. Two FreeBSD-specific patches applied automatically:
   - DuckDB's `Makefile` uses GNU-make-only syntax, so the build invokes
     `gmake` (not BSD `make`).
   - DuckDB's vendored mbedtls calls `explicit_bzero` without including
     `<strings.h>` — fine on Linux glibc but breaks on FreeBSD. The script
     prepends the include.
3. Creates the `survey` system user and the `/var/db/survey`,
   `/var/log/survey` directories.
4. Writes `/usr/local/etc/survey/survey.env` with a freshly-generated 32-byte
   Quack token. **Prints the token to stdout once** — save it. Binds the
   service to `0.0.0.0:8080` (HTTP click handler) and `0.0.0.0:9494` (Quack)
   so an external reverse proxy can reach it across the LAN.
5. Installs `/usr/local/etc/rc.d/survey` and enables it via `sysrc`.
6. Writes `/usr/local/etc/sudoers.d/survey-deploy` so that `make deploy`,
   `make logs`, `make status` work passwordless from the laptop. The grant
   is restricted to the specific survey-related commands those targets call.

## Skip the source build: use FreeBSD's pkg

DuckDB is in the FreeBSD ports tree (`databases/duckdb`). If the `pkg`
branch you're on has the version `install-on-server.sh` is configured for
(`DUCKDB_VER`), the script will install it via `pkg` and skip the
download/build paths entirely.

The catch: the default branch is **`quarterly`** which updates every 3
months, so it can be a minor version behind. The **`latest`** branch
tracks current ports.

**Check your branch and what pkg has:**

```sh
grep url /etc/pkg/FreeBSD.conf      # quarterly or latest?
pkg search -q duckdb                 # shows the version pkg would install
```

**Switch to `latest`** (one-time, idempotent override of the base config):

```sh
mkdir -p /usr/local/etc/pkg/repos
cat > /usr/local/etc/pkg/repos/FreeBSD.conf <<'EOF'
FreeBSD: {
  url: "pkg+http://pkg.FreeBSD.org/${ABI}/latest",
  mirror_type: "srv",
  signature_type: "fingerprints",
  fingerprints: "/usr/share/keys/pkg",
  enabled: yes
}
EOF
pkg update -f
pkg upgrade -y                       # aligns all installed packages with `latest`
```

**Warning**: `latest` is a per-host decision. Future `pkg upgrade` will pull
newer versions of every installed package (Caddy, Listmonk, etc.). On a
single-purpose VM that's fine; on a host running other production services
you may want to stay on `quarterly` and use the GHA prebuild path below.

The FreeBSD port installs headers under `/usr/local/include/duckdb/`, but
the Go binding expects `duckdb.h` directly in `/usr/local/include/`. The
script symlinks them automatically after a `pkg install`.

Set `SKIP_PKG=1` to bypass this path and force download/build.

## Skip the source build: download a prebuilt libduckdb

For small/low-RAM FreeBSD hosts (mine is 512 MB), the from-source DuckDB
build can OOM or take many hours. There's a GitHub Actions workflow that
builds `libduckdb.so` + headers + the `duckdb` CLI inside a FreeBSD VM on a
beefy GitHub-hosted runner and publishes them as a release asset.

**Trigger the build once:**

1. Go to GitHub → **Actions** → **build-freebsd-libduckdb** → **Run workflow**.
2. Enter the DuckDB version (default `1.5.3`). Click **Run workflow**.
3. ~20 min later, a release tagged `freebsd-libduckdb-v<ver>` appears with a
   `freebsd-libduckdb-v<ver>.tar.gz` asset attached.

**Use it:**

`install-on-server.sh` step 2 tries `fetch` from the release URL **before**
falling back to a source build. So once the release exists for your
`DUCKDB_VER`, `make install-on-server` will download the ~50 MB tarball
(seconds) instead of compiling (hours).

Override the source repo if you forked: `LIBDUCKDB_REPO=youruser/yourfork make install-on-server`.
Force a from-source build instead: `SKIP_PREBUILT=1 make install-on-server`.

## Build-time gotchas you'll hit

- **`sudo: a terminal is required to read the password`** — only happens if
  you try to run `make install-on-server` from the laptop side over SSH. Do
  it inside an interactive `su root` session instead.
- **DuckDB source build is slow on small hosts.** On a low-RAM VM with heavy
  swap, the 479-step compile can take an hour or more. Detach with `tmux`
  and check back. The build is idempotent — `gmake` resumes from where
  `ninja` last stopped.
- **`pkg upgrade -y git pcre2` if git fails to start.** Stale lib-version
  skew is a recurring FreeBSD issue; the script attempts a targeted upgrade
  and bails with a useful error if `git --version` still fails.

## Override DuckDB version

```sh
make push-installer DUCKDB_VER=1.5.4
# then on the host:
make install-on-server DUCKDB_VER=1.5.4
```

The two version overrides must match — the Go binary links dynamically
against the system `libduckdb.so` via `-tags=duckdb_use_lib`.

## Why FreeBSD specifically

I have a FreeBSD machine already running other services
(`ti.sspaeti.duckdns.org`). Reusing it costs nothing. The complexity above
is the cost of FreeBSD's second-class status in the DuckDB ecosystem — not
inherent complexity in the survey tool itself. On Linux, the whole install
collapses to a `go build` + a systemd unit.
