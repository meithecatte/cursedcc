#!/usr/bin/env bash
set -eu

. diagnostics.sh
. parse.sh

if [ ! -f "$1" ]; then
    fail "Usage: $0 file"
fi

declare filename="$1"

# XXX: this approach to reading a file causes a fork(), but all the alternatives
# I've seen so far (read and mapfile) read the file one byte at a time, which is
# worse.
declare src
src="$(< "$filename")"

lex
parse

if (( error_count > 0 )); then
    exit 1
fi

declare -p ast
