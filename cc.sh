#!/usr/bin/env bash
set -eu
shopt -s extglob

SELFDIR="$(dirname -- "${BASH_SOURCE[0]}")"

. "$SELFDIR/binpack.sh"
. "$SELFDIR/diagnostics.sh"
. "$SELFDIR/parse.sh"
. "$SELFDIR/elf.sh"
. "$SELFDIR/jumps.sh"
. "$SELFDIR/backend.sh"

declare objonly=0 preprocessed=0

usage() {
    echo "Usage: $0 [-c] [-p] [-o outfile] file" >&2
    exit 1
}

while getopts "co:p" opt; do
    case $opt in
        c) objonly=1;;
        o) outfile="$OPTARG";;
        p) preprocessed=1;;
        *) usage;;
    esac
done

shift $((OPTIND - 1))

if [ -z "${1-}" ]; then
    usage
fi

declare filename="$1"

if (( preprocessed == 1 )); then
    # shellcheck disable=SC2094 # don't worry, we're not writing to $filename
    lex "$filename" < "$filename"
else
    # A normal pipeline will run `lex` in a subprocess, losing the ability
    # to modify our variables
    lex "$filename" < <(cc -E "$filename")
fi

parse

if (( error_count > 0 )); then
    exit 1
fi

declare -p functions
declare -p ast

sections[.text]=""
section_types[.text]="$SHT_PROGBITS"
section_attrs[.text]=$((SHF_ALLOC | SHF_EXECINSTR))

for function in "${!functions[@]}"; do
    emit_function "$function"
done

if (( error_count > 0 )); then
    exit 1
fi

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
