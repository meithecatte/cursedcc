#!/usr/bin/env bash
set -eu

SELFDIR="$(dirname -- "${BASH_SOURCE[0]}")"

. "$SELFDIR/binpack.sh"
. "$SELFDIR/diagnostics.sh"
. "$SELFDIR/parse.sh"
. "$SELFDIR/elf.sh"

if [ -z "${1-}" ]; then
    fail "Usage: $0 file"
fi

declare filename="$1"

declare src
src="$(< "$filename")"

lex
parse

if (( error_count > 0 )); then
    exit 1
fi

declare -p ast

sections[.text]="\xc3"
section_types[.text]="$SHT_PROGBITS"
section_attrs[.text]=$(($SHF_ALLOC | $SHF_EXECINSTR))

symbol_sections[main]=.text
symbol_offsets[main]=0

emit_elf out.o
