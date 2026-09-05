#!/usr/bin/env bash

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
"$SCRIPT_DIR/budget" server
status=$?

if [ "$status" -ne 0 ]; then
    printf '\nBudget server stopped with status %s.\n' "$status"
    printf 'Press Return to close this window.\n'
    read -r _
fi

exit "$status"
