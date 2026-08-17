#!/bin/sh
# Every flavour value must be quoted: flavour-setup.sh sources these files, so
# an unquoted value containing a space is executed as a command.
set -eu
d="${1:-flavours}"; bad=0
for f in "$d"/*.env; do
    if grep -E '^RCC_[A-Z0-9_]+=' "$f" | grep -qvE '^RCC_[A-Z0-9_]+="'; then
        echo "unquoted value in $f:" >&2
        grep -E '^RCC_[A-Z0-9_]+=' "$f" | grep -vE '^RCC_[A-Z0-9_]+="' | sed 's/^/  /' >&2
        bad=1
    fi
    ( set -eu; . "./$f" ) >/dev/null 2>&1 || { echo "does not source cleanly: $f" >&2; bad=1; }
done
[ "$bad" -eq 0 ] && echo "flavours ok"
exit "$bad"
