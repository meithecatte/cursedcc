#!/usr/bin/env bash

filename="write_a_c_compiler/stage_1/valid/return_2.c"

# XXX: this approach to reading a file causes a fork(), but all the alternatives
# I've seen so far (read and mapfile) read the file one byte at a time, which is
# worse.
src="$(< "$filename")"

function fail() {
    echo "$@" >&2
    exit 1
}

# Tokens are stored in a SoA representation.
declare -a toktype # type of token, e.g. ident, lbrace
declare -a tokdata # associated data, e.g. the actual identifier or literal value
declare -ia tokbegin tokend # input byte range that corresponds to this token

# token type begin end data
function token() {
    local -i idx=${#toktype[@]}
    toktype[idx]="$1"
    tokbegin[idx]="$2"
    tokend[idx]="$3"
    if (( $# >= 4 )); then
        tokdata[idx]="$4"
    fi
}

function lex() {
    declare -i i
    for (( i=0; i < ${#src}; i++ )); do
        declare c="${src:i:1}"
        declare -i begin=i
        case "$c" in
            ' ' | $'\n' | $'\t' | $'\r');;
            [_a-zA-Z])
                local ident="$c"
                while [[ "${src:i+1:1}" =~ [_A-Za-z0-9] ]]; do
                    ((i=i+1))
                    ident+="${src:i:1}"
                done
                token ident $begin $i "$ident";;
            [0-9])
                local num="$c"
                while [[ "${src:i+1:1}" =~ [0-9] ]]; do
                    ((i=i+1))
                    num+="${src:i:1}"
                done
                token literal $begin $i "$num";;
            "(") token lparen $begin $i;;
            ")") token rparen $begin $i;;
            "{") token lbrace $begin $i;;
            "}") token rbrace $begin $i;;
            ";") token semi $begin $i;;
            *) echo "$c unknown";;
        esac
    done
}

lex
