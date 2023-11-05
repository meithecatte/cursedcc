# The preprocessed lines. Each line may come from a different file.
declare -a lines=()
# The file and line number for each line in `lines`.
declare -a line_map=()

# Tokens are stored in a SoA representation.
# type of token, e.g. ident, lbrace
declare -a toktype=()
# actual text context of token
declare -a tokdata=()
# input line (index to `lines`) and offset within that line
declare -ia tokline=() tokcol=()

# token type begin end
token() {
    local type="$1"
    local -i idx=${#toktype[@]} line=${#lines[@]}-1 begin="$2" end="$3"
    toktype[idx]="$type"
    tokdata[idx]="${lines[-1]:begin:end-begin+1}"
    tokline[idx]="$line"
    tokcol[idx]="$begin"
}

declare in_multiline_comment=

# lex filename < input
lex() {
    local -i eof=0 lineno=1
    local filename="$1"
    while (( eof == 0 )); do
        IFS= read -r line || eof=1
        if [[ "${line:0:1}" == "#" ]]; then
            # Preprocessor linemarker
            local marker=($line)
            lineno="${marker[1]}"
            : "${line##\# *([0-9]) \"}"
            : "${_%%\"*([0-9]| )}"
            filename="${_//\\\"/\"}"
        else
            local -i index=${#lines[@]}
            lines+=("$line")
            line_map+=("${filename}:${lineno}")
            lexline $index "$line"

            lineno+=1
        fi
    done

    if [ -n "$in_multiline_comment" ]; then
        local -a pos=($in_multiline_comment)
        local -i line="${pos[0]}" col="${pos[1]}"
        error "unclosed block comment"
        show_range $line $col $((col + 1)) "comment begins here"
        end_diagnostic
    fi
}

# lexline line_index line
lexline() {
    local -i curline=$1 i
    local line="$2"

    for (( i=0; i < ${#line}; i++ )); do
        if [ -n "$in_multiline_comment" ]; then
            if [[ "${line:i:2}" == "*/" ]]; then
                in_multiline_comment=
                i+=1
            fi

            continue
        fi

        if [[ "${line:i:2}" == "//" ]]; then
            return
        elif [[ "${line:i:2}" == "/*" ]]; then
            in_multiline_comment="$curline $i"
            i+=1
            continue
        fi

        local c="${line:i:1}"
        local -i begin=i
        case "$c" in
            ' ' | $'\n' | $'\t' | $'\r');;
            [_a-zA-Z0-9])
                local ident="$c"
                while [[ "${line:i+1:1}" =~ [_A-Za-z0-9] ]]; do
                    ((i=i+1))
                    ident+="${line:i:1}"
                done

                if [[ "${ident:0:1}" =~ [0-9] ]]; then
                    if [ -n "${ident//[0-9]/}" ]; then
                        error "invalid identifier"
                        show_range $curline $begin $i \
                            "identifier can't start with a digit"
                        end_diagnostic
                    else
                        token literal $begin $i
                    fi
                else
                    case "$ident" in
                        alignof|auto|break|case|char|const|continue|default|do|\
                        double|else|enum|extern|float|for|goto|if|inline|int|\
                        long|register|restrict|return|short|signed|sizeof|static|\
                        struct|switch|typedef|union|unsigned|void|volatile|while|\
                        _Alignas|_Atomic|_Bool|_Complex|_Generic|_Imaginary|\
                        _Noreturn|_Static_assert|_Thread_local)
                            token "kw:$ident" $begin $i;;
                        *)
                            token ident $begin $i;;
                    esac
                fi;;
            "(") token lparen $begin $i;;
            ")") token rparen $begin $i;;
            "{") token lbrace $begin $i;;
            "}") token rbrace $begin $i;;
            ";") token semi $begin $i;;
            "+") token plus $begin $i;;
            "-") token minus $begin $i;;
            "*") token star $begin $i;;
            "/") token div $begin $i;;
            "%") token mod $begin $i;;
            "!") token logical_not $begin $i;;
            "~") token bitwise_not $begin $i;;
            *)
                error "stray '$c' in program"
                show_range $curline $i $i
                end_diagnostic;;
        esac
    done
}

show_tokens() {
    local -i i
    for (( i=0; i < ${#toktype[@]}; i++ )); do
        show_token $i "${toktype[i]} ${tokdata[i]}"
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

# 6.5.1 Primary expressions Primary expressions
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

# 6.5.3 Unary operators
parse_unary_expr() {
    check_expr_start

    case "${toktype[pos]}" in
    plus)
        expect minus
        parse_unary_expr
        mknode "unary_plus $res";;
    minus)
        expect minus
        parse_unary_expr
        mknode "negate $res";;
    bitwise_not)
        expect bitwise_not
        parse_unary_expr
        mknode "bitwise_not $res";;
    logical_not)
        expect logical_not
        parse_unary_expr
        mknode "logical_not $res";;
    *)  parse_primary_expr;;
    esac
}

# 6.5.5 Multiplicative operators
parse_mult_expr() {
    parse_unary_expr
    local result=$res

    while has_tokens; do
        case "${toktype[pos]}" in
        star)
            expect star
            parse_unary_expr
            mknode "mul $result $res"
            result=$res;;
        div)
            expect div
            parse_unary_expr
            mknode "div $result $res"
            result=$res;;
        mod)
            expect mod
            parse_unary_expr
            mknode "mod $result $res"
            result=$res;;
        *)  break;;
        esac
    done

    res=$result
}

# 6.5.6 Additive operators
parse_add_expr() {
    parse_mult_expr
    local result=$res

    while has_tokens; do
        case "${toktype[pos]}" in
        plus)
            expect plus
            parse_mult_expr
            mknode "add $result $res"
            result=$res;;
        minus)
            expect minus
            parse_mult_expr
            mknode "sub $result $res"
            result=$res;;
        *)  break;;
        esac
    done

    res=$result
}

parse_expr() {
    parse_add_expr
}
