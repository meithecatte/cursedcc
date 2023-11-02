#!/usr/bin/env bash
set -eu

SELFDIR="$(dirname -- "${BASH_SOURCE[0]}")"

. "$SELFDIR/binpack.sh"
. "$SELFDIR/diagnostics.sh"
. "$SELFDIR/parse.sh"
. "$SELFDIR/elf.sh"
. "$SELFDIR/backend.sh"

declare objonly=0

usage() {
    fail "Usage: $0 [-c] [-o outfile] file"
}

while getopts "co:" opt; do
    case $opt in
        c) objonly=1;;
        o) outfile="$OPTARG";;
        *) usage;;
    esac
done

shift $((OPTIND - 1))

if [ -z "${1-}" ]; then
    usage
fi

declare filename="$1"

declare src
src="$(< "$filename")"

lex
parse

if (( error_count > 0 )); then
    exit 1
fi

declare -p functions
declare -p ast

sections[.text]="\x31\xc0\xc3"
section_types[.text]="$SHT_PROGBITS"
section_attrs[.text]=$((SHF_ALLOC | SHF_EXECINSTR))

for function in "${!functions[@]}"; do
    emit_function "$function"
done

if (( objonly == 1 )); then
    if [ -z "${outfile-}" ]; then
        objfile="${filename%.c}.o"
    else
        objfile="$outfile"
    fi
else
    objfile="$(mktemp ccsh.XXXXXXXXXX.o)"
    # shellcheck disable=SC2064 # we *do* want it to expand now.
    trap "rm -- '$objfile'" EXIT
fi

emit_elf "$objfile"

if (( objonly == 0 )); then
    if [ -z "${outfile-}" ]; then
        outfile="${filename%.c}"
    fi

    cc -o "${outfile}" "$objfile"
fi
