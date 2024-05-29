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

declare -A token_names=(
    [lparen]="(" [rparen]=")"
    [lbrace]="{" [rbrace]="}"
    [lbrack]="[" [rbrack]="]"
    [semi]=";"
    [plus]="+"  [pluseq]="+="   [incr]="++"
    [minus]="-" [minuseq]="-="  [decr]="--"
    [star]="*"  [stareq]="*="
    [div]="/"   [diveq]="/="
    [mod]="%"   [modeq]="%="
    [xor]="^"   [xoreq]="^="
    [band]="&"  [bandeq]="&="   [land]="&&"
    [bor]="|"   [boreq]="|="    [lor]="||"
    [assn]="="  [eq]="=="
    [lt]="<"    [le]="<="
    [gt]=">"    [ge]=">="
    [shl]="<<"  [shleq]="<<="
    [shr]=">>"  [shreq]=">>="
    [lnot]="!"  [noteq]="!="
    [bnot]="~"
    [comma]="," [colon]=":" [question]="?"
)

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
            *)

                local -i longest=0
                local longest_token=
                for token_name in "${!token_names[@]}"; do
                    local token="${token_names["$token_name"]}"
                    if [[ "${line:i}" =~ ^"$token" ]]; then
                        if (( ${#token} > longest )); then
                            longest=${#token}
                            longest_token=$token_name
                        fi
                    fi
                done

                if [ -z "$longest_token" ]; then
                    error "stray '$c' in program"
                    show_range $curline $i $i
                    end_diagnostic
                else
                    i+=longest-1
                    token $longest_token $begin $i
                fi;;
        esac
    done
}

# For debugging the lexer
show_tokens() {
    local -i i
    for (( i=0; i < ${#toktype[@]}; i++ )); do
        show_token $i "${toktype[i]} ${tokdata[i]}"
    done
}

declare -i pos=0
declare -a ast=() ast_pos=()
# Maps function name to the fundecl at point of definition
declare -A functions=()

# mknode node begin
mknode() {
    local end=${3-$((pos - 1))}
    local begin=${2-$end}
    res=${#ast[@]}
    ast+=("$1")
    ast_pos+=("$begin $end")
}

# try_unpack node expected_type params...
try_unpack() {
    local _node=$1 _expected=$2
    if ! [[ "$_node" =~ ^[0-9]*$ && -n "${ast[_node]-}" ]]; then
        internal_error "invalid index $_node for try_unpack"
        exit 1
    fi

    local _parts=(${ast[_node]})
    if [[ "$_expected" != "${_parts[0]}" ]]; then
        return 1
    fi

    shift 2
    for _part in "${_parts[@]:1}"; do
        local -n _ref=$1; shift 1
        _ref="$_part"
    done
}

# unpack node expected_type params...
unpack() {
    if ! try_unpack "$@"; then
        local _parts=(${ast[$1]})
        internal_error "expected node of type $2, got ${_parts[0]}"
        show_node $1 "${_parts[*]}"
        end_diagnostic
        exit 1
    fi
}

has_tokens() {
    (( pos < ${#toktype[@]} ))
}

# spell_token token_type
spell_token() {
    case $1 in
    ident)   spelled="identifier";;
    literal) spelled="literal";;
    kw:*)    spelled="\`${1#kw:}\`";;
    *)       spelled="\`${token_names["$1"]}\`";;
    esac
}

# expect token_type
# expect token_type data_out
expect() {
    local token_type="$1"
    if ! has_tokens; then
        spell_token "$token_type"
        error "expected ${spelled}, got EOF"
        show_eof "${spelled} expected here"
        end_diagnostic
        return 1
    fi

    if [[ "${toktype[pos]}" != "${token_type}" ]]; then
        spell_token "$token_type"; local spelled_expected=$spelled
        spell_token "${toktype[pos]}"; local spelled_actual=$spelled
        error "expected ${spelled_expected}, got ${spelled_actual}"
        show_token $pos "${spelled_expected} expected here"
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

# 6.9 External definitions
# translation-unit:
#     external-declaration
#     translation-unit external-declaration
parse() {
    while has_tokens; do
        parse_external_declaration
    done
}

# 6.9 External definitions
# external-declaration:
#     function-definition
#     declaration
#
# 6.9.1 Function definitions
# function-definition:
#     declaration-specifiers declarator declaration-list? compound-statement
#
# 6.7 Declarations
# declaration:
#     declaration-specifiers init-declarator-list?
#
# init-declarator-list:
#     init-declarator
#     init-declarator-list , init-declarator
#
# init-declarator:
#     declarator
#     declarator = initializer
parse_external_declaration() {
    local begin=$pos
    parse_declaration_specifiers; local specifiers=$res
    if peek semi; then
        useless_specifiers $specifiers
        return
    fi

    parse_declarator; local declarator=$res
    if peek lbrace; then
        local ty var
        unfuck_declarator $declarator $specifiers
        local name="${ast[var]#var }"
        local ty_ret params

        if ! try_unpack $ty ty_fun ty_ret params; then
            error "expected \`,\` or \`;\`, found \`{\`"
            show_token $pos "unexpected \`{\`"
            show_node $var "not a function"
            end_diagnostic
            return 1
        fi

        mknode "declare_var $ty $var" $begin; local fundecl=$res
        scope_insert $name $fundecl

        parse_compound; local body=$res
        if [ -n "${functions[$name]-}" ]; then
            error "function \`$name\` is defined twice"
            show_node ${functions[$name]} "\`$name\` first defined here"
            show_node $fundecl "\`$name redefined here"
            end_diagnostic
            return
        fi

        functions[$name]=$fundecl
        emit_function $name $params $body
    else
        finish_declaration $specifiers $declarator
        emit_global $res
    fi
}

# useless_specifiers specifiers
useless_specifiers() {
    expect semi
    warning "useless empty declaration"
    show_node $1 "useless empty declaration"
    end_diagnostic
    mknode "nothing"
}

# 6.7 Declarations
# declaration:
#     declaration-specifiers init-declarator-list? ;
peek_declaration() {
    peek_declaration_specifiers
}

parse_declaration() {
    parse_declaration_specifiers; local specifiers=$res
    if peek semi; then
        useless_specifiers $specifiers
        return
    fi

    parse_declarator; local declarator=$res
    finish_declaration $specifiers $declarator
}

# Pick up parsing a `declaration` after
#     declaration-specifiers declarator
#
# declaration:
#     declaration-specifiers init-declarator-list?
#
# init-declarator-list:
#     init-declarator
#     init-declarator-list , init-declarator
#
# init-declarator:
#     declarator
#     declarator = initializer
finish_declaration() {
    local specifiers=$1 declarator=$2 vars=()

    finish_init_declarator $specifiers $declarator
    vars+=($res)

    while peek comma; do
        expect comma
        parse_declarator; declarator=$res
        finish_init_declarator $specifiers $declarator
        vars+=($res)
    done

    expect semi
    mknode "declare ${vars[*]}"
}

finish_init_declarator() {
    local specifiers=$1 declarator=$2
    local begin=(${ast_pos[declarator]})
    local ty var
    unfuck_declarator $declarator $specifiers
    if peek assn; then
        expect assn
        parse_initializer; local value=$res
        mknode "declare_var $ty $var $value" $begin
    else
        mknode "declare_var $ty $var" $begin
    fi
}

# 6.7.9 Initialization
# initializer:
#     assignment-expression
#     { initializer-list }
#     { initializer-list , }
parse_initializer() {
    # TODO: non-trivial initializers
    parse_assignment_expr
    mknode "expr $res"
}

# 6.7 Declarations
# mvp grammar
peek_declaration_specifiers() {
    peek kw:int || peek kw:void
}

parse_declaration_specifiers() {
    if peek kw:int; then
        expect kw:int
        mknode "ty_int"
    elif peek kw:void; then
        expect kw:void
        mknode "ty_void"
    fi
}

# 6.7.6 Declarators
# declarator:
#     pointer? direct-declarator
parse_declarator() {
    # TODO: handle pointer types
    parse_direct_declarator
}

# 6.7.6 Declarators
# direct-declarator:
#     identifier
#     ( declarator )
#     ... # TODO
#     direct-declarator ( parameter-type-list )
parse_direct_declarator() {
    local begin=$pos
    if peek lparen; then
        expect lparen
        parse_declarator; local cur=$res
        expect rparen
    else
        expect ident; local name="$expect_tokdata"
        mknode "var $name"; local cur=$res
    fi

    while peek lparen; do
        expect lparen
        parse_parameter_type_list; local params=$res
        expect rparen
        mknode "decl_fun $cur $params" $begin; local cur=$res
    done
}

# 6.7.6 Declarators
# parameter-type-list:
#     parameter-list
#     parameter-list , ...
#
# parameter-list:
#     parameter-declaration
#     parameter-list , parameter-declaration
parse_parameter_type_list() {
    local param_list=()
    local begin=$pos

    parse_parameter_declaration
    param_list+=($res)

    while peek comma; do
        expect comma
        # TODO: handle ellipsis
        parse_parameter_declaration
        param_list+=($res)
    done

    check_param_list "${param_list[@]}"
}

# 6.7.6 Declarators
# parameter-declaration:
#     declaration-specifiers declarator
#     declaration-specifiers abstract-declarator? # TODO
parse_parameter_declaration() {
    local begin=$pos
    parse_declaration_specifiers; local specifiers=$res

    if peek rparen || peek comma; then
        mknode "declare_var $specifiers"
    else
        parse_declarator; local declarator=$res
        local ty var
        unfuck_declarator $declarator $specifiers

        mknode "declare_var $ty $var" $begin
    fi
}

# 6.8.2 Compound statement
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

        if peek_declaration; then
            parse_declaration
            stmts+=("$res")
        else
            parse_statement
            stmts+=("$res")
        fi
    done
    expect rbrace

    mknode "compound ${stmts[*]}" $lbrace_pos
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

# 6.8 Statements and blocks
parse_statement() {
    if ! has_tokens; then
        error "expected statement, got EOF"
        show_eof
        end_diagnostic
        return 1
    fi

    local begin=$pos

    # 6.8.1 Labeled statements
    if (( pos + 1 < ${#toktype[@]} )) \
        && [[ "${toktype[pos]}" == "ident" ]] \
        && [[ "${toktype[pos+1]}" == "colon" ]]
    then
        expect ident; local label=$expect_tokdata
        local end=$pos
        expect colon
        parse_statement
        mknode "label $label $res" $begin $end
        return
    fi

    case "${toktype[pos]}" in
    # 6.8.4 Selection statements
    # 6.8.4.1 The if statement
    kw:if)
        expect kw:if
        expect lparen
        parse_expr; local cond=$res
        expect rparen
        parse_statement; local then=$res
        if peek kw:else; then
            pos+=1
            parse_statement; local else=$res
            mknode "if $cond $then $else" $begin
        else
            mknode "if $cond $then" $begin
        fi;;

    # 6.8.5 Iteration statements
    # 6.8.5.1 The while statement
    kw:while)
        expect kw:while
        expect lparen
        parse_expr; local cond=$res
        expect rparen
        parse_statement; local body=$res

        mknode "while $cond $body" $begin;;
    # 6.8.5.2 The do statement
    kw:do)
        expect kw:do
        parse_statement; local body=$res
        expect kw:while
        expect lparen
        parse_expr; local cond=$res
        expect rparen
        parse_semi

        mknode "dowhile $body $cond" $begin;;
    # 6.8.5.3 The for statement
    kw:for)
        expect kw:for
        expect lparen
        if peek semi; then
            expect semi
            mknode "nothing"; local init=$res
        elif peek_declaration; then
            parse_declaration; local init=$res
        else
            parse_expr; mknode "expr $res"; local init=$res
            parse_semi
        fi

        if peek semi; then
            pos+=1
            mknode "literal 1"; local cond=$res
        else
            parse_expr; local cond=$res
            parse_semi
        fi

        if ! peek rparen; then
            parse_expr; mknode "expr $res"; local step=$res
        else
            mknode "nothing"; local step=$res
        fi

        expect rparen
        parse_statement; local body=$res

        mknode "for $cond $step $body" $begin
        mknode "compound $init $res";;

    # 6.8.6 Jump statements
    # 6.8.6.1 The goto statement
    kw:goto)
        expect kw:goto
        local label_pos=$pos
        expect ident; local label=$expect_tokdata
        parse_semi

        mknode "goto $label $label_pos" $begin;;
    # 6.8.6.2 The continue statement
    kw:continue)
        expect kw:continue
        parse_semi

        mknode "continue" $begin;;
    # 6.8.6.3 The break statement
    kw:break)
        expect kw:break
        parse_semi

        mknode "break" $begin;;
    # 6.8.6.4 The return statement
    kw:return)
        expect kw:return
        parse_expr; local retval=$res
        parse_semi

        mknode "return $retval" $begin;;

    # 6.8.2 Compound statement
    lbrace) parse_compound;;

    # 6.8.3 Expression and null statements
    semi)
        expect semi
        mknode "nothing" $begin;;
    *)
        parse_expr; local expr=$res
        parse_semi
        mknode "expr $expr" $begin;;
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
        end_diagnostic
        return 1;;
    esac
}

# 6.5.1 Primary expressions
parse_primary_expr() {
    check_expr_start

    local begin=$pos
    case "${toktype[pos]}" in
    literal)
        expect literal
        mknode "literal $expect_tokdata" $begin;;
    ident)
        expect ident
        mknode "var $expect_tokdata" $begin;;
    lparen)
        expect lparen
        parse_expr; local result=$res
        expect rparen
        res=$result;;
    *)
        error "expression not recognized"
        show_token $pos
        end_diagnostic
        return 1;;
    esac
}

# 6.5.2 Postfix operators
parse_postfix_expr() {
    local begin=$pos
    parse_primary_expr || return 1

    while has_tokens; do
        local lhs=$res

        case "${toktype[pos]}" in
        lparen)
            expect lparen
            local args=()
            if ! peek rparen; then
                parse_assignment_expr
                args+=($res)
                while peek comma; do
                    expect comma
                    parse_assignment_expr
                    args+=($res)
                done
            fi
            expect rparen
            mknode "call $lhs ${args[*]}" $begin;;
        *)
            break;;
        esac
    done
}

# 6.5.3 Unary operators
parse_unary_expr() {
    check_expr_start

    case "${toktype[pos]}" in
    plus)   pos+=1; parse_unary_expr; mknode "unary_plus $res";;
    minus)  pos+=1; parse_unary_expr; mknode "negate $res";;
    bnot)   pos+=1; parse_unary_expr; mknode "bnot $res";;
    lnot)   pos+=1; parse_unary_expr; mknode "lnot $res";;
    *)      parse_postfix_expr;;
    esac
}

# Note: the finish_* parsers are necessary because of the grammar
# of the assignment expressions: one would need to parse an unary_expr,
# try to consume an assignment operator, and if that fails, backtrack
# and parse a conditional_expr. Instead of backtracking, we call
# finish_conditional_expr.
finish_unary_expr() {
    :
}

declare prev_level=unary_expr

# left_level this [tok node]...
left_level() {
    local this="$1"; shift
    local parse_code="parse_$this() { parse_$prev_level; "
    local finish_code="finish_$this() { finish_$prev_level; "
    local code='while has_tokens; do local lhs=$res; case "${toktype[pos]}" in '
    while (( $# >= 2 )); do
        code+=$"$1) pos+=1; parse_$prev_level; mknode \"$2 \$lhs \$res\";; "
        shift 2
    done
    code+=$'*) break;; esac; done; }'
    eval "$parse_code$code"
    eval "$finish_code$code"
    prev_level=$this
}

# 6.5.5 Multiplicative operators
left_level mult_expr \
    star mul    div  div    mod  mod

# 6.5.6 Additive operators
left_level add_expr \
    plus add    minus sub

# 6.5.7 Bitwise shift operators
left_level shift_expr \
    shl shl     shr shr

# 6.5.8 Relational operators
left_level relational_expr \
    lt lt       gt gt \
    le le       ge ge

# 6.5.9 Equality operators
left_level equality_expr \
    eq eq       noteq noteq

# 6.5.10 Bitwise AND operator
left_level and_expr \
    band band

# 6.5.11 Bitwise exclusive OR operator
left_level xor_expr \
    xor xor

# 6.5.12 Bitwise inclusive OR operator
left_level or_expr \
    bor bor

# 6.5.13 Logical AND operator
left_level land_expr \
    land land

# 6.5.14 Logical OR operator
left_level lor_expr \
    lor lor

# 6.5.15 Conditional operator
parse_conditional_expr() {
    parse_unary_expr
    finish_conditional_expr
}

finish_conditional_expr() {
    local begin=$pos
    finish_lor_expr; local cond=$res

    if peek question; then
        expect question
        parse_expr; local yes=$res
        expect colon
        parse_conditional_expr; local no=$res
        mknode "ternary $cond $yes $no" $begin
    fi
}

# 6.5.17 Assignment operators
parse_assignment_expr() {
    local begin=$pos
    parse_unary_expr
    if ! has_tokens; then return; fi

    case "${toktype[pos]}" in
    assn|pluseq|minuseq|stareq|diveq|modeq|shleq|shreq|bandeq|boreq|xoreq)
        local lhs=$res op="${toktype[pos]}" assn_pos=$pos
        pos+=1
        parse_assignment_expr; local rhs=$res
        mknode "$op $lhs $rhs $assn_pos" $begin;;
    *)  finish_conditional_expr;;
    esac
}

parse_expr() {
    parse_assignment_expr
}
