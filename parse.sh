#!/usr/bin/env bash

declare filename="$1"

# XXX: this approach to reading a file causes a fork(), but all the alternatives
# I've seen so far (read and mapfile) read the file one byte at a time, which is
# worse.
declare src="$(< "$filename")"

. diagnostics.sh

# Tokens are stored in a SoA representation.
declare -a toktype # type of token, e.g. ident, lbrace
declare -a tokdata # associated data, e.g. the actual identifier or literal value
declare -ia tokbegin tokend # input byte range that corresponds to this token

# token type begin end data
token() {
    local -i idx=${#toktype[@]}
    toktype[idx]="$1"
    tokbegin[idx]="$2"
    tokend[idx]="$3"
    if (( $# >= 4 )); then
        tokdata[idx]="$4"
    fi
}

lex() {
    local -i i
    for (( i=0; i < ${#src}; i++ )); do
        local c="${src:i:1}"
        local -i begin=i
        case "$c" in
            ' ' | $'\n' | $'\t' | $'\r');;
            [_a-zA-Z])
                local ident="$c"
                while [[ "${src:i+1:1}" =~ [_A-Za-z0-9] ]]; do
                    ((i=i+1))
                    ident+="${src:i:1}"
                done
                case "$ident" in
                    alignof|auto|break|case|char|const|continue|default|do|\
                    double|else|enum|extern|float|for|goto|if|inline|int|\
                    long|register|restrict|return|short|signed|sizeof|static|\
                    struct|switch|typedef|union|unsigned|void|volatile|while|\
                    _Alignas|_Atomic|_Bool|_Complex|_Generic|_Imaginary|\
                    _Noreturn|_Static_assert|_Thread_local)
                        token "kw:$ident" $begin $i "$ident";;
                    *)
                        token ident $begin $i "$ident";;
                esac;;
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
            *)
                error "stray '$c' in program"
                show_range $i $i
                end_diagnostic;;
        esac
    done
}

show_tokens() {
    local -i i
    for (( i=0; i < ${#toktype[@]}; i++ )); do
        show_range ${tokbegin[i]} ${tokend[i]} "${toktype[i]} ${tokdata[i]}"
    done
}

lex
show_tokens
