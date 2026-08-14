#!/bin/bash
# shellcheck shell=bash
# Minimal test helpers. Sourced by tests/test-*.sh.
#
# No framework on purpose: the whole point of this suite is that it runs on a
# machine with no container runtime, no R and no network, so that CI can catch
# a broken flavor definition or a broken parser in seconds rather than after a
# forty-minute image build.

TESTS_RUN=0
TESTS_FAILED=0
CURRENT_TEST=""

t_begin() { CURRENT_TEST=$1; TESTS_RUN=$((TESTS_RUN + 1)); }

t_fail() {
    TESTS_FAILED=$((TESTS_FAILED + 1))
    printf 'FAIL  %s\n' "$CURRENT_TEST" >&2
    printf '      %s\n' "$1" >&2
    [ $# -gt 1 ] && printf '      %s\n' "$2" >&2
    return 0
}

t_pass() { printf 'ok    %s\n' "$CURRENT_TEST"; }

assert_eq() {
    local expected=$1 actual=$2
    if [ "$expected" = "$actual" ]; then
        t_pass
    else
        t_fail "expected: $expected" "actual:   $actual"
    fi
}

assert_contains() {
    local haystack=$1 needle=$2
    case $haystack in
        *"$needle"*) t_pass ;;
        *) t_fail "expected output to contain: $needle" "got: $(printf '%s' "$haystack" | head -c 400)" ;;
    esac
}

assert_not_contains() {
    local haystack=$1 needle=$2
    case $haystack in
        *"$needle"*) t_fail "expected output NOT to contain: $needle" ;;
        *) t_pass ;;
    esac
}

assert_ok() {
    if "$@" >/dev/null 2>&1; then t_pass; else t_fail "command failed: $*"; fi
}

assert_fails() {
    if "$@" >/dev/null 2>&1; then t_fail "command unexpectedly succeeded: $*"; else t_pass; fi
}

t_summary() {
    printf '\n%s: %d test(s), %d failure(s)\n' "${0##*/}" "$TESTS_RUN" "$TESTS_FAILED"
    [ "$TESTS_FAILED" -eq 0 ]
}
