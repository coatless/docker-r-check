#!/bin/bash
# Run the whole suite. No container runtime, no R, no network required.
#
#   tests/run-tests.sh            everything
#   tests/run-tests.sh flavors    just tests/test-flavors.sh
#
# The one thing this suite deliberately cannot tell you is whether the images
# build and whether a flavor reproduces CRAN's verdict. That needs a real
# build; see .github/workflows/images.yml and docs/evaluation-protocol.md.

set -u
here=$(cd "$(dirname "$0")" && pwd)

if [ $# -gt 0 ]; then
    files=""
    for name in "$@"; do files="$files $here/test-$name.sh"; done
else
    files=$(ls "$here"/test-*.sh)
fi

failed=0
total_tests=0
total_failures=0

for f in $files; do
    [ -f "$f" ] || { echo "no such test file: $f" >&2; failed=1; continue; }
    printf '\n=== %s ===\n' "${f##*/}"
    out=$(bash "$f" 2>&1)
    status=$?
    printf '%s\n' "$out"
    ## The per-file summary line is "name.sh: N test(s), M failure(s)".
    line=$(printf '%s' "$out" | grep -E ': [0-9]+ test\(s\), [0-9]+ failure\(s\)$' | tail -n 1)
    if [ -n "$line" ]; then
        n=$(printf '%s' "$line" | sed -E 's/.*: ([0-9]+) test\(s\).*/\1/')
        m=$(printf '%s' "$line" | sed -E 's/.*, ([0-9]+) failure\(s\)$/\1/')
        total_tests=$((total_tests + n))
        total_failures=$((total_failures + m))
    fi
    [ $status -eq 0 ] || failed=1
done

printf '\n================================================================\n'
printf 'TOTAL: %d test(s), %d failure(s)\n' "$total_tests" "$total_failures"
if [ $failed -eq 0 ]; then
    printf 'PASS\n'
else
    printf 'FAIL\n'
fi
exit $failed
