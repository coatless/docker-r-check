#!/bin/bash
# Flavor definitions must be valid, complete and honest about their own status.

set -u
here=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$here/.." && pwd)
. "$here/lib.sh"

export RCHECK_FLAVOR_PATH="$REPO/flavors"
. "$REPO/docker/lib/flavor.sh"

flavors=$(rcheck_flavor_list)

t_begin "at least the Tier 1 set is defined"
missing=""
for want in nold nosuggests donttest gcc-asan gcc-ubsan clang-asan clang-ubsan; do
    case " $(echo $flavors) " in *" $want "*) ;; *) missing="$missing $want" ;; esac
done
assert_eq "" "$missing"

t_begin "rcheck lint passes"
assert_ok "$REPO/bin/rcheck" lint

for id in $flavors; do
    t_begin "flavor $id loads"
    if ( rcheck_flavor_load "$id" ) >/dev/null 2>&1; then t_pass; else t_fail "load failed"; fi

    ( rcheck_flavor_load "$id" ) >/dev/null 2>&1 || continue
    rcheck_flavor_load "$id"

    t_begin "flavor $id emits valid JSON"
    out=$(rcheck_flavor_json)
    if command -v python3 >/dev/null 2>&1; then
        if printf '%s' "$out" | python3 -c 'import json,sys; json.load(sys.stdin)' 2>/dev/null; then
            t_pass
        else
            t_fail "rcheck_flavor_json produced invalid JSON for $id"
        fi
    else
        assert_contains "$out" "\"FLAVOR_ID\": \"$id\""
    fi

    t_begin "flavor $id documents why it may differ from CRAN"
    ## Every flavor claims to reproduce a CRAN check on a host that is not
    ## CRAN's. If it does not say so anywhere, the claim is being overstated,
    ## and an overstated claim is the failure mode this whole project is
    ## exposed to. Enforce that NOTES is substantive.
    if [ ${#NOTES} -ge 80 ]; then t_pass; else t_fail "$id: NOTES is too short to explain the flavor (${#NOTES} chars)"; fi

    t_begin "flavor $id declaring a CRAN issue kind names a real one"
    case ${CRAN_ISSUE_KIND:-} in
        ""|noLD|noOMP|noSuggests|donttest|valgrind|ATLAS|BLAS|MKL|OpenBLAS|LTO|\
        clang-ASAN|clang-UBSAN|gcc-ASAN|gcc-UBSAN|rchk|rcnst|rlibro|C23|Intel|\
        noRemap|Strict|0len|M1mac|musl|linux-arm64|vnu|gcc|gcc15|gcc16)
            t_pass ;;
        *)  t_fail "$id: CRAN_ISSUE_KIND='$CRAN_ISSUE_KIND' is not a kind listed at check_issue_kinds.html" ;;
    esac

    t_begin "flavor $id needing compiler control does not use CRAN's build-R"
    ## build-R chooses its own configure invocation, so a flavor that sets CC or
    ## passes configure arguments and still asks for cran-qa would silently
    ## build an uninstrumented R -- and then report agreement with CRAN while
    ## having tested nothing.
    if [ -n "$R_CC$R_CXX$R_CONFIGURE_ARGS" ] && [ "$R_BUILD_METHOD" = cran-qa ]; then
        t_fail "$id sets compiler/configure options but uses R_BUILD_METHOD=cran-qa"
    else
        t_pass
    fi

    t_begin "flavor $id sanitizer flags reach package code via CC/CXX"
    ## Putting -fsanitize only in CFLAGS instruments R itself but not packages
    ## that override CFLAGS in their own Makevars, which is most compiled
    ## packages of any size.
    case ${CRAN_ISSUE_KIND:-} in
        *ASAN|*UBSAN)
            if [ -n "$R_CC" ] && [ -n "$R_CXX" ]; then t_pass
            else t_fail "$id is a sanitizer flavor but does not set both R_CC and R_CXX"; fi ;;
        *) t_pass ;;
    esac

    t_begin "flavor $id avoids host-specific optimisation flags"
    ## -march=native / -mtune=native make the build depend on the CPU that ran
    ## it, which defeats cross-host reproducibility.
    case "$R_CFLAGS$R_CXXFLAGS$R_FFLAGS$R_CC$R_CXX" in
        *-march=native*|*-mtune=native*) t_fail "$id uses a native-CPU flag, which is not reproducible across hosts" ;;
        *) t_pass ;;
    esac
done

t_begin "no two flavors claim the same CRAN issue kind"
dupes=$(for id in $flavors; do
            ( rcheck_flavor_load "$id"; [ -n "$CRAN_ISSUE_KIND" ] && echo "$CRAN_ISSUE_KIND" )
        done | sort | uniq -d)
assert_eq "" "$dupes"

t_begin "every base image used by a flavor is pinned"
assert_ok "$REPO/tools/pin-images.sh" --check

## --- applying a flavor ----------------------------------------------------

TMP=$(mktemp -d) || exit 1
trap 'rm -rf "$TMP"' EXIT

t_begin "sanitizer flags land in CC/CXX in the generated config.site"
rcheck_flavor_load gcc-asan
rcheck_flavor_write_config_site "$TMP/config.site"
assert_contains "$(cat "$TMP/config.site")" "CC='gcc -fsanitize=address"

t_begin "  ... and the main link gets the sanitizer too"
assert_contains "$(cat "$TMP/config.site")" "MAIN_LDFLAGS='-fsanitize=address'"

t_begin "a flavor with no compiler overrides writes no compiler settings"
rcheck_flavor_load debian-gcc
rcheck_flavor_write_config_site "$TMP/config.site"
assert_not_contains "$(cat "$TMP/config.site")" "CC="

t_begin "check.Renviron gets the flavor's settings"
printf '## pre-existing\n_R_CHECK_KEEP_=yes\n' > "$TMP/check.Renviron"
rcheck_flavor_load nosuggests
rcheck_flavor_write_check_renviron "$TMP/check.Renviron"
assert_contains "$(cat "$TMP/check.Renviron")" "_R_CHECK_SUGGESTS_ONLY_=true"

t_begin "  ... without discarding what CRAN's own settings put there"
assert_contains "$(cat "$TMP/check.Renviron")" "_R_CHECK_KEEP_=yes"

t_begin "  ... and writing it repeatedly does not accumulate duplicates"
## Under docker the home is fresh each run so this never shows; under apptainer
## it persists, and an appending writer would grow the file on every check.
rcheck_flavor_write_check_renviron "$TMP/check.Renviron"
rcheck_flavor_write_check_renviron "$TMP/check.Renviron"
assert_eq 1 "$(grep -c '_R_CHECK_SUGGESTS_ONLY_' "$TMP/check.Renviron" | tr -d ' ')"

t_begin "a flavor with no check-time settings leaves no file behind"
rm -f "$TMP/check.Renviron"
rcheck_flavor_load nold
rcheck_flavor_write_check_renviron "$TMP/check.Renviron"
if [ -f "$TMP/check.Renviron" ]; then t_fail "created a check.Renviron with nothing in it"; else t_pass; fi

t_begin "runtime env is exported for the sanitizer runtimes"
( rcheck_flavor_load gcc-asan
  rcheck_flavor_export_runtime_env
  case ${ASAN_OPTIONS:-} in *detect_leaks=0*) exit 0 ;; *) exit 1 ;; esac ) \
  && t_pass || t_fail "ASAN_OPTIONS was not exported"

t_begin "a malformed CHECK_RUNTIME_ENV line is rejected, not exported blindly"
cat > "$TMP/badenv.conf" <<'CONF'
FLAVOR_ID=badenv
FLAVOR_TITLE="malformed runtime env"
CRAN_HOST_OS="test"
TIER=1
STATUS=experimental
BASE_FAMILY=debian
BASE_IMAGE=docker.io/debian
BASE_TAG=unstable
R_BUILD_METHOD=cran-qa
CHECK_RUNTIME_ENV="
this is not an assignment
"
CONF
( RCHECK_FLAVOR_PATH=$TMP rcheck_flavor_load badenv >/dev/null 2>&1
  RCHECK_FLAVOR_PATH=$TMP rcheck_flavor_export_runtime_env >/dev/null 2>&1 ) \
  && t_fail "malformed CHECK_RUNTIME_ENV was accepted" || t_pass

t_summary
