# shellcheck shell=bash
# shellcheck disable=SC2034  # the variables are used by the scripts that source this
# Settings and helpers shared by the demo scripts.  Sourced, not executed.
#
# Everything here can be overridden from the environment:
#
#   RCC_ENGINE     docker (default) or podman
#   RCC_PLATFORM   linux/amd64 (default). Every arm is amd64. On an arm64
#                  host this turns on emulation.
#   R_SVN_REV      R-devel revision to build (default: the one CI builds)
#   QA_SVN_REV     revision of CRAN/QA/Kurt (default: the one CI builds)
#   RCC_JOBS       make -j for the R build (default 4)
#   RCC_RESULTS    where downloads, logs and check results go (default ./results)
#   CRAN_MIRROR    where package sources are fetched from

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENGINE="${RCC_ENGINE:-docker}"
PLATFORM="${RCC_PLATFORM:-linux/amd64}"
R_SVN_REV="${R_SVN_REV:-90410}"
QA_SVN_REV="${QA_SVN_REV:-6927}"
CRAN="${CRAN_MIRROR:-https://cloud.r-project.org}"
RESULTS="${RCC_RESULTS:-$ROOT/results}"

die() { echo "error: $*" >&2; exit 2; }

image() { echo "rcc-standalone:$1"; }

flavours() { ls "$ROOT/docker/flavours" | sed -n 's/\.env$//p'; }

have_flavour() { [ -r "$ROOT/docker/flavours/$1.env" ]; }

have_image() { "$ENGINE" image inspect "$(image "$1")" >/dev/null 2>&1; }

need_image() {
    have_flavour "$1" || die "no such flavour '$1' (one of: $(flavours | tr '\n' ' '))"
    have_image "$1" || die "$(image "$1") is not built; run demo/01-build.sh $1"
}

# fetch_cran <package> <dir> downloads the current source tarball of a CRAN
# package and prints its path. The version comes from PACKAGES, because
# src/contrib only serves the newest one.
fetch_cran() {
    local p="$1" d="$2" v idx
    mkdir -p "$d"
    # One index per mirror, since live CRAN and a dated snapshot differ.
    idx="$d/PACKAGES.$(printf '%s' "$CRAN" | cksum | cut -d' ' -f1)"
    if [ ! -s "$idx" ] || [ -n "$(find "$idx" -mmin +60 2>/dev/null)" ]; then
        curl -fsSL -o "$idx" "$CRAN/src/contrib/PACKAGES" \
            || die "cannot fetch $CRAN/src/contrib/PACKAGES"
    fi
    v="$(awk -v p="$p" '$0 == "Package: " p {f = 1; next} f && /^Version:/ {print $2; exit}' "$idx")"
    [ -n "$v" ] || die "$p is not a current package on $CRAN"
    if [ ! -s "$d/${p}_$v.tar.gz" ]; then
        curl -fsSL -o "$d/${p}_$v.tar.gz" "$CRAN/src/contrib/${p}_$v.tar.gz" \
            || die "cannot fetch ${p}_$v.tar.gz"
    fi
    echo "$d/${p}_$v.tar.gz"
}

sha256() { { sha256sum "$1" 2>/dev/null || shasum -a 256 "$1"; } | cut -d' ' -f1; }

# snapshot_date [days-ago] prints a UTC date for a dated CRAN snapshot URL.
snapshot_date() {
    local n="${1:-1}"
    date -u -d "$n days ago" +%Y-%m-%d 2>/dev/null || date -u -v-"${n}"d +%Y-%m-%d
}

# check_status <00check.log> prints the Status line's result, or nothing.
check_status() {
    [ -f "$1" ] || return 0
    sed -n 's/^Status: //p' "$1" | tail -n 1
}
