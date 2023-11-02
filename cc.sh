#!/usr/bin/env bash
set -eu

. binpack.sh
. diagnostics.sh
. parse.sh
. elf.sh

if [ ! -f "$1" ]; then
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

emit_elf out.o
