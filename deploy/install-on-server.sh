#!/bin/sh
#
# One-shot FreeBSD installer for minimal-newsletter-survey.
# Runs LOCALLY on the FreeBSD host AS ROOT. Invoke via `make install-on-server`
# after `su root` in your ssh session. Idempotent — safe to rerun.
#
# Steps:
#   1. pkg install build deps: go, rsync, git, cmake, ninja, gmake, python3
#   2. Build & install DuckDB ${DUCKDB_VER} from source under /usr/local
#      (skipped if /usr/local/bin/duckdb already reports the right version)
#   3. Create `survey` system user, /var/db/survey, /var/log/survey
#   4. Generate Quack token, write /usr/local/etc/survey/survey.env
#      (binds to 0.0.0.0 so an external reverse proxy like NPM can reach it.
#       Firewall the ports LAN-only if your network needs it.)
#   5. Install /usr/local/etc/rc.d/survey and enable it via sysrc
#   6. Write /usr/local/etc/sudoers.d/survey-deploy so `make deploy` works
#      passwordless from the laptop (sspaeti only, specific commands only)
#
# TLS termination is done by your external reverse proxy (e.g. Nginx Proxy
# Manager on Unraid), NOT by Caddy on this host. Configure two proxy hosts:
#   survey.sspaeti.duckdns.org  →  http://<ti-LAN-ip>:8080
#   quack.sspaeti.duckdns.org   →  http://<ti-LAN-ip>:9494

set -eu

if [ "$(id -u)" -ne 0 ]; then
    echo "error: run as root (do 'su root' first)" >&2
    exit 1
fi

DUCKDB_VER="${DUCKDB_VER:-1.5.3}"
PREFIX="${PREFIX:-/usr/local}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DUCKDB_SRC="${PREFIX}/src/duckdb-${DUCKDB_VER}"

echo "==> 1/6 Installing build dependencies (pkg)"
# gmake is required: DuckDB's Makefile uses GNU-make-only syntax (ifeq/ifneq).
pkg install -y go rsync git cmake ninja gmake python3
# Heal stale dep skew on the host (e.g. installed git linked against an
# older libpcre2 than what's now on disk). Targets only the packages we'll
# actually use plus their auto-upgraded deps, so this won't touch unrelated
# services on the box.
pkg upgrade -y go rsync git cmake ninja gmake python3 pcre2 || true
# Verify git actually runs — if not, the user needs `pkg upgrade -y` system-wide.
if ! git --version >/dev/null 2>&1; then
    echo "" >&2
    echo "error: git is installed but won't run (likely stale lib dep)." >&2
    echo "       Run 'pkg upgrade -y' and rerun this script." >&2
    exit 1
fi

echo "==> 2/6 DuckDB ${DUCKDB_VER}"
current_ver=""
if [ -x "${PREFIX}/bin/duckdb" ]; then
    current_ver=$("${PREFIX}/bin/duckdb" -noheader -csv -batch \
        -c "SELECT library_version FROM pragma_version();" 2>/dev/null \
        | tr -d 'v"' || true)
fi
if [ "${current_ver}" = "${DUCKDB_VER}" ] \
        && [ -f "${PREFIX}/lib/libduckdb.so" ] \
        && [ -f "${PREFIX}/include/duckdb.h" ]; then
    echo "    DuckDB ${DUCKDB_VER} already installed at ${PREFIX}"
else
    DUCKDB_INSTALLED=0

    # --- Option A: try pkg first (cheapest if the repo has the right version) ---
    # The 'latest' pkg branch usually has the current DuckDB; 'quarterly' lags
    # by up to 3 months. To switch: write /usr/local/etc/pkg/repos/FreeBSD.conf
    # pointing at .../latest (see docs/install-freebsd.md). Set SKIP_PKG=1 to
    # bypass this option.
    if [ -z "${SKIP_PKG:-}" ]; then
        pkg_avail=$(pkg search -q duckdb 2>/dev/null | grep "^duckdb-${DUCKDB_VER}\(_[0-9]*\)\?\$" | head -1 || true)
        if [ -n "${pkg_avail}" ]; then
            echo "    pkg has ${pkg_avail}; installing via pkg"
            pkg install -y duckdb
            # The FreeBSD port puts headers under /usr/local/include/duckdb/;
            # the Go binding expects them at /usr/local/include/duckdb.h.
            [ -f "${PREFIX}/include/duckdb.h" ] || \
                ln -sf duckdb/duckdb.h "${PREFIX}/include/duckdb.h" 2>/dev/null || true
            [ -f "${PREFIX}/include/duckdb.hpp" ] || \
                ln -sf duckdb/duckdb.hpp "${PREFIX}/include/duckdb.hpp" 2>/dev/null || true
            if [ -f "${PREFIX}/lib/libduckdb.so" ] && [ -f "${PREFIX}/include/duckdb.h" ]; then
                DUCKDB_INSTALLED=1
            else
                echo "    pkg install didn't produce expected files; falling through"
            fi
        else
            echo "    pkg has no duckdb-${DUCKDB_VER} (quarterly branch is likely stale); trying download"
        fi
    fi

    # --- Option B: download prebuilt artifact from GitHub Releases ---
    # Set SKIP_PREBUILT=1 to force a from-source build.
    LIBDUCKDB_REPO="${LIBDUCKDB_REPO:-sspaeti/minimial-newsletter-survey}"
    LIBDUCKDB_URL="${LIBDUCKDB_URL:-https://github.com/${LIBDUCKDB_REPO}/releases/download/freebsd-libduckdb-v${DUCKDB_VER}/freebsd-libduckdb-v${DUCKDB_VER}.tar.gz}"
    if [ "${DUCKDB_INSTALLED}" = "0" ] && [ -z "${SKIP_PREBUILT:-}" ]; then
        echo "    trying prebuilt: ${LIBDUCKDB_URL}"
        dl_tmp=$(mktemp -d)
        if fetch -q -o "${dl_tmp}/d.tgz" "${LIBDUCKDB_URL}" 2>/dev/null; then
            echo "    downloaded prebuilt; extracting to ${PREFIX}"
            tar xzf "${dl_tmp}/d.tgz" -C "${dl_tmp}"
            EXTRACT_DIR="${dl_tmp}/freebsd-libduckdb-v${DUCKDB_VER}"
            install -m 0644 "${EXTRACT_DIR}"/lib/libduckdb.so* "${PREFIX}/lib/" 2>/dev/null || true
            install -m 0644 "${EXTRACT_DIR}"/include/*.h*       "${PREFIX}/include/" 2>/dev/null || true
            install -m 0755 "${EXTRACT_DIR}"/bin/duckdb         "${PREFIX}/bin/"     2>/dev/null || true
            if [ -f "${PREFIX}/lib/libduckdb.so" ] && [ -f "${PREFIX}/include/duckdb.h" ]; then
                DUCKDB_INSTALLED=1
            else
                echo "    prebuilt tarball was incomplete; falling back to source build"
            fi
        else
            echo "    prebuilt not available; falling back to source build"
        fi
        rm -rf "${dl_tmp}"
    fi

    # --- Option B: build from source ---
    if [ "${DUCKDB_INSTALLED}" = "0" ]; then
        mkdir -p "${PREFIX}/src"
        if [ ! -d "${DUCKDB_SRC}" ]; then
            echo "    cloning duckdb v${DUCKDB_VER} into ${DUCKDB_SRC}..."
            git clone --branch "v${DUCKDB_VER}" --depth 1 \
                https://github.com/duckdb/duckdb.git "${DUCKDB_SRC}"
        fi
        # FreeBSD declares explicit_bzero in <strings.h>; DuckDB's vendored mbedtls
        # doesn't include it, so the build fails on this file. Idempotent prepend.
        PLATFORM_UTIL="${DUCKDB_SRC}/third_party/mbedtls/library/platform_util.cpp"
        if [ -f "${PLATFORM_UTIL}" ] && ! grep -q '<strings.h>' "${PLATFORM_UTIL}"; then
            echo "    patching mbedtls platform_util.cpp for FreeBSD explicit_bzero"
            tmp=$(mktemp)
            printf '#include <strings.h>\n' > "${tmp}"
            cat "${PLATFORM_UTIL}" >> "${tmp}"
            mv "${tmp}" "${PLATFORM_UTIL}"
        fi
        echo "    building (this takes ~20 minutes, longer on small RAM)..."
        cd "${DUCKDB_SRC}"
        GEN=ninja gmake
        echo "    installing to ${PREFIX}..."
        cmake --install build/release --prefix "${PREFIX}" || true
        # Fallback: some DuckDB releases don't install libduckdb.so / duckdb.h
        # via their cmake install rules. Copy directly if still missing.
        if [ ! -f "${PREFIX}/lib/libduckdb.so" ]; then
            echo "    cmake install didn't place libduckdb.so; copying manually"
            find build/release -name 'libduckdb.so*' -exec install -m 0644 {} "${PREFIX}/lib/" \;
        fi
        if [ ! -f "${PREFIX}/include/duckdb.h" ]; then
            echo "    copying duckdb.h manually"
            find src/include -maxdepth 2 -name 'duckdb.h'   -exec install -m 0644 {} "${PREFIX}/include/" \;
            find src/include -maxdepth 2 -name 'duckdb.hpp' -exec install -m 0644 {} "${PREFIX}/include/" \; 2>/dev/null || true
        fi
        cd - >/dev/null
    fi
fi

echo "==> 3/6 User & directories"
# HOME=/var/db/survey (a real dir we own) so that daemon(8) setusercontext()
# doesn't fail with "failed to set user environment" — happens when HOME
# points to /nonexistent.
if ! id survey >/dev/null 2>&1; then
    pw useradd survey -d /var/db/survey -s /usr/sbin/nologin -c "survey service"
else
    # Heal already-existing survey user that was created with HOME=/nonexistent.
    pw usermod survey -d /var/db/survey >/dev/null 2>&1 || true
fi
mkdir -p /var/db/survey /var/log/survey "${PREFIX}/etc/survey"
chown survey:survey /var/db/survey /var/log/survey

echo "==> 4/6 Environment file"
ENV_FILE="${PREFIX}/etc/survey/survey.env"
if [ ! -f "${ENV_FILE}" ]; then
    TOKEN=$(head -c 32 /dev/urandom | base64 | tr -d '\n')
    umask 077
    cat > "${ENV_FILE}" <<EOF
SURVEY_DB_PATH=/var/db/survey/votes.duckdb
SURVEY_HTTP_ADDR=0.0.0.0:8080
SURVEY_QUACK_ADDR=0.0.0.0:9494
SURVEY_BLOG_URL=https://www.ssp.sh
SURVEY_QUACK_TOKEN=${TOKEN}
EOF
    chown survey:survey "${ENV_FILE}"
    echo ""
    echo "    +--------------------------------------------------------------+"
    echo "    | Quack token (save — used to ATTACH from your laptop):        |"
    echo "    |   ${TOKEN}"
    echo "    +--------------------------------------------------------------+"
    echo ""
else
    echo "    ${ENV_FILE} already exists; not regenerating token"
fi

echo "==> 5/6 rc.d service"
install -m 0755 "${SCRIPT_DIR}/survey.rc" "${PREFIX}/etc/rc.d/survey"
sysrc survey_enable=YES >/dev/null

echo "==> 6/6 Passwordless sudo for deploy"
DEPLOY_USER="${DEPLOY_USER:-sspaeti}"
DEPLOY_HOME="${DEPLOY_HOME:-/home/${DEPLOY_USER}}"
SUDOERS_FILE="${PREFIX}/etc/sudoers.d/survey-deploy"
umask 077
cat > "${SUDOERS_FILE}" <<EOF
# Generated by install-on-server.sh — allows 'make deploy' from the laptop
# without prompting for a password. Restricted to specific survey ops only.
${DEPLOY_USER} ALL=(root) NOPASSWD: /bin/cp ${DEPLOY_HOME}/survey-src/build/survey ${PREFIX}/bin/survey.new
${DEPLOY_USER} ALL=(root) NOPASSWD: /bin/mv ${PREFIX}/bin/survey.new ${PREFIX}/bin/survey
${DEPLOY_USER} ALL=(root) NOPASSWD: /usr/sbin/service survey *
${DEPLOY_USER} ALL=(root) NOPASSWD: /usr/bin/tail -f /var/log/survey/survey.log
EOF
chmod 0440 "${SUDOERS_FILE}"
# Validate; remove file if syntax is bad so sudo isn't broken
if ! visudo -c -f "${SUDOERS_FILE}" >/dev/null 2>&1; then
    echo "    visudo rejected ${SUDOERS_FILE}; removing it"
    rm -f "${SUDOERS_FILE}"
fi

echo ""
echo "==> Setup complete."
echo ""
echo "    The service is enabled but not yet started. Exit root and ssh, then:"
echo "        make deploy"
echo "    from your laptop. That builds the Go binary and starts the service."
echo ""
echo "    Reverse proxy expected (do this in NPM if not already done):"
echo "        survey.sspaeti.duckdns.org  ->  http://<ti-LAN-ip>:8080"
echo "        quack.sspaeti.duckdns.org   ->  http://<ti-LAN-ip>:9494"
