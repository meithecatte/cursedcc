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
        elif [[ "${src:i:2}" == "/*" ]]; then
            local -i comment_begin=i
            i+=2

            while (( i < ${#src} )) && [[ "${src:i:2}" != "*/" ]]; do
                i+=1
            done

            if (( i >= ${#src} )); then
                error "unclosed block comment"
                show_range $comment_begin $((comment_begin + 1)) \
                    "comment begins here"
                end_diagnostic
                continue
            else
                i+=2
                continue
            fi
        fi

        local c="${src:i:1}"
        local -i begin=i
        case "$c" in
            ' ' | $'\n' | $'\t' | $'\r');;
            [_a-zA-Z0-9])
                local ident="$c"
                while [[ "${src:i+1:1}" =~ [_A-Za-z0-9] ]]; do
                    ((i=i+1))
                    ident+="${src:i:1}"
                done

                if [[ "${ident:0:1}" =~ [0-9] ]]; then
                    if [ -n "${ident//[0-9]/}" ]; then
                        error "invalid identifier"
                        show_range $begin $i "identifier can't start with a digit"
                        end_diagnostic
                    else
                        token literal $begin $i "$ident"
                    fi
                else
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
                    esac
                fi;;
            "(") token lparen $begin $i;;
            ")") token rparen $begin $i;;
            "{") token lbrace $begin $i;;
            "}") token rbrace $begin $i;;
            ";") token semi $begin $i;;
            "+") token plus $begin $i;;
            "-") token minus $begin $i;;
            "!") token logical_not $begin $i;;
            "~") token bitwise_not $begin $i;;
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

# mknode node
mknode() {
    res=${#ast[@]}
    ast+=("$1")
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

    expect_tokdata="${tokdata[pos]-}"

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
    expect kw:int
    expect ident
    local name="$expect_tokdata"
    expect lparen
    expect kw:void
    expect rparen

    parse_compound
    functions[$name]=$res
}

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

        parse_statement
        stmts+=("$res")
    done
    expect rbrace

    mknode "compound ${stmts[*]}"
}

# expect a semicolon. if not present, consume tokens until found
parse_semi() {
    expect semi || recover_semi
}

# TODO: recovery is currently not exercised as well as it could due to `set -e`.
# Even then, it'd probably need some more heuristics to be useful.
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

# parse_statement
parse_statement() {
    if ! has_tokens; then
        error "expected statement, got EOF"
        show_eof
        end_diagnostic
        return 1
    fi

    case "${toktype[pos]}" in
    kw:return)
        pos+=1
        parse_expr
        local retval=$res
        parse_semi

        mknode "return $retval";;
    *)
        error "statement not recognized"
        show_token $pos
        end_diagnostic

        recover_semi
        return 1;;
    esac
}

check_expr_start() {
    if ! has_tokens; then
        error "expected expression, got EOF"
        show_eof
        end_diagnostic
        return 1
    fi

    case "${toktype[pos]}" in
    semi|rparen|rbrace)
        error "expected expression"
        show_token $pos
        end_diagnostic;;
    esac
}

parse_primary_expr() {
    check_expr_start

    case "${toktype[pos]}" in
    literal)
        expect literal
        mknode "literal $expect_tokdata";;
    lparen)
        expect lparen
        parse_expr
        local result=$res
        expect rparen
        res=$result;;
    *)
        error "expression not recognized"
        show_token $pos
        end_diagnostic;;
    esac
}

parse_expr() {
    check_expr_start

    case "${toktype[pos]}" in
    plus)
        expect minus
        parse_expr
        mknode "unary_plus $res";;
    minus)
        expect minus
        parse_expr
        mknode "negate $res";;
    bitwise_not)
        expect bitwise_not
        parse_expr
        mknode "bitwise_not $res";;
    logical_not)
        expect logical_not
        parse_expr
        mknode "logical_not $res";;
    *)  parse_primary_expr;;
    esac
}
