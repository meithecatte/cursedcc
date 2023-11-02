# Tokens are stored in a SoA representation.
# type of token, e.g. ident, lbrace
declare -a toktype=()
# associated data, e.g. the actual identifier or literal value
declare -a tokdata=()
# input byte range that corresponds to this token
declare -ia tokbegin=() tokend=()

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
        if [[ "${src:i:2}" == "//" ]]; then
            while (( i < ${#src} )) && [[ "${src:i:1}" != $'\n' ]]; do
                i+=1
            done

            continue
        fi

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

declare -i pos=0
declare -a ast=()
declare -Ai functions

# mknode out node
mknode() {
    local -n mknode_out=$1
    mknode_out=${#ast[@]}
    ast+=("$2")
}

has_tokens() {
    (( pos < ${#toktype[@]} ))
}

# expect token_type
# expect token_type data_out
expect() {
    local token_type="$1"
    if ! has_tokens; then
        error "expected ${token_type}, got EOF"
        show_eof "${token_type} expected here"
        end_diagnostic
        return 1
    fi

    if [[ "${toktype[pos]}" != "${token_type}" ]]; then
        error "expected ${token_type}, got ${toktype[pos]}"
        show_token $pos "${token_type} expected here"
        end_diagnostic
        return 1
    fi

    if (( $# >= 2 )); then
        local -n out="$2"
        out="${tokdata[pos]}"
    fi

    pos+=1
}

# peek token_type
# succeeds if the next token is token_type
peek() {
    has_tokens || return 1
    [[ "${toktype[pos]}" == "$1" ]]
}

parse() {
    while has_tokens; do
        parse_function
    done
}

parse_function() {
    local name
    expect kw:int
    expect ident name
    expect lparen
    expect kw:void
    expect rparen

    local body
    parse_compound body
    functions[$name]=$body
}

# parse_compound out
parse_compound() {
    local -i lbrace_pos=$pos
    expect lbrace
    local -a stmts=()
    while ! peek rbrace; do
        if ! has_tokens; then
            error "unclosed block"
            show_token $lbrace_pos "block opened here"
            show_eof "closing brace expected here"
            end_diagnostic
            return 1
        fi

        local stmt
        parse_statement stmt
        stmts+=("$stmt")
    done
    expect rbrace

    mknode $1 "compound ${stmt[*]}"
}

# expect a semicolon. if not present, consume tokens until found
parse_semi() {
    expect semi || recover_semi
}

recover_semi() {
    while has_tokens; do
        case "${toktype[pos]}" in
        semi)
            pos+=1
            return;;
        rbrace)
            return;;
        *)
            pos+=1;;
        esac
    done
}

# parse_statement out
parse_statement() {
    has_tokens || return 1
    case "${toktype[pos]}" in
    kw:return)
        pos+=1
        local retval
        parse_expr retval
        parse_semi

        mknode $1 "return $retval";;
    *)
        error "statement not recognized"
        show_token $pos
        end_diagnostic

        recover_semi
        return 1;;
    esac
}

# parse_expr out
parse_expr() {
    local -n out="$1"
    has_tokens || return 1
    case "${toktype[pos]}" in
    literal)
        expect literal n
        mknode out "literal $n";;
    semi|rparen|rbrace)
        error "expected expression"
        show_token $pos
        end_diagnostic
        out=error;;
    *)
        error "expression not recognized"
        show_token $pos
        end_diagnostic
        out=error;;
    esac
}
