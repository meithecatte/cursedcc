STACK_ALIGNMENT=16

EAX=0
ECX=1
EDX=2
EBX=3
ESP=4; RSP=4
EBP=5; RBP=5

CC_E=4
CC_Z=4
CC_NE=5
CC_NZ=5
CC_L=12
CC_GE=13
CC_LE=14
CC_G=15

# The code generation strategy for everything involving jumps requires
# generating the code being jumped over to a separate variable, so that its
# size can later be measured.
declare -a code_arr=("")
declare -i code_cur=0
declare -n code="code_arr[code_cur]"

nest() {
    code_cur+=1
    code_arr[code_cur]=""
}

# sets res, reslen
unnest() {
    res="$code"
    binlength reslen "$res"
    unset code_arr[code_cur]
    code_cur=code_cur-1
}

modrm_reg() {
    # reg - register field
    # rm - r/m field (register index)
    local reg="$1" rm="$2"
    p8 code $((0xc0 + 8 * reg + rm))
}

modrm_rbpoff() {
    local reg="$1" offset="$2"
    if (( -128 <= offset && offset <= 127 )); then
        p8 code $((0x45 + 8 * reg))
        p8 code $offset
    else
        p8 code $((0x85 + 8 * reg))
        p32 code $offset
    fi
}

leave() {
    code+="\xc9"
}

ret() {
    code+="\xc3"
}

mov_reg_imm() {
    local reg="$1" imm="$2"
    p8 code $((0xb8 + reg))
    p32 code "$imm"
}

mov_reg_reg() {
    local dst="$1" src="$2"
    code+="\x89"
    modrm_reg "$src" "$dst"
}

mov_rbpoff_reg() {
    local offset="$1" src="$2"
    code+="\x89"
    modrm_rbpoff "$src" "$offset"
}

mov_reg_rbpoff() {
    local dst="$1" offset="$2"
    code+="\x8b"
    modrm_rbpoff "$dst" "$offset"
}

movq_reg_reg() {
    local dst="$1" src="$2"
    code+="\x48\x89"
    modrm_reg "$src" "$dst"
}

not_reg() {
    local reg="$1"
    code+="\xf7"
    modrm_reg 2 "$reg"
}

neg_reg() {
    local reg="$1"
    code+="\xf7"
    modrm_reg 3 "$reg"
}

shl_reg_cl() {
    local reg="$1"
    code+="\xd3"
    modrm_reg 4 "$reg"
}

shr_reg_cl() {
    local reg="$1"
    code+="\xd3"
    modrm_reg 5 "$reg"
}

sar_reg_cl() {
    local reg="$1"
    code+="\xd3"
    modrm_reg 7 "$reg"
}

push_reg() {
    local reg="$1"
    p8 code $((0x50 + reg))
}

pop_reg() {
    local reg="$1"
    p8 code $((0x58 + reg))
}

add_reg_reg() {
    local dst="$1" src="$2"
    code+="\x01"
    modrm_reg "$src" "$dst"
}

or_reg_reg() {
    local dst="$1" src="$2"
    code+="\x09"
    modrm_reg "$src" "$dst"
}

and_reg_reg() {
    local dst="$1" src="$2"
    code+="\x21"
    modrm_reg "$src" "$dst"
}

sub_reg_reg() {
    local dst="$1" src="$2"
    code+="\x29"
    modrm_reg "$src" "$dst"
}

subq_reg_imm() {
    local dst="$1" imm="$2"
    if (( -128 <= imm && imm <= 127 )); then
        code+="\x48\x83"
        modrm_reg 5 "$dst"
        p8 code "$imm"
    else
        code+="\x48\x81"
        modrm_reg 5 "$dst"
        p32 code "$imm"
    fi
}

xor_reg_reg() {
    local dst="$1" src="$2"
    code+="\x31"
    modrm_reg "$src" "$dst"
}

cmp_reg_reg() {
    local dst="$1" src="$2"
    code+="\x39"
    modrm_reg "$src" "$dst"
}

test_reg_reg() {
    local dst="$1" src="$2"
    code+="\x85"
    modrm_reg "$src" "$dst"
}

imul_reg_reg() {
    local dst="$1" src="$2"
    code+="\x0f\xaf"
    modrm_reg "$dst" "$src"
}

cdq() {
    code+="\x99"
}

idiv_reg() {
    local reg="$1"
    code+="\xf7"
    modrm_reg 7 "$reg"
}

movzxb_reg_reg() {
    local dst="$1" src="$2"
    code+="\x0f\xb6"
    modrm_reg "$src" "$dst"
}

setcc_reg() {
    local cc="$1" dst="$2"
    code+="\x0f"
    p8 code $((0x90 + cc))
    modrm_reg 0 "$dst"
}

jmp_forward() {
    local dist="$1"
    if (( dist == 0 )); then
        return
    elif (( dist < 0x80 )); then
        code+="\xeb"
        p8 code $dist
    else
        code+="\xe9"
        p32 code $dist
    fi
}

jcc_forward() {
    local cc="$1" dist="$2"
    if (( dist == 0 )); then
        return
    elif (( dist < 0x80 )); then
        p8 code $((0x70 + cc))
        p8 code $dist
    else
        code+="\x0f"
        p8 code $((0x80 + cc))
        p32 code $dist
    fi
}

# AST traversal starts here

# measure_stack stmt
measure_stack() {
    local -a stmt=(${ast[$1]})
    case ${stmt[0]} in
        compound)
            local -i stack_used=$stack_used
            local -i i
            for (( i=1; i < ${#stmt[@]}; i++ )); do
                measure_stack ${stmt[i]}
            done;;
        if)
            measure_stack ${stmt[2]}
            if [ -n "${stmt[3]-}" ]; then
                measure_stack ${stmt[3]}
            fi;;
        declare)
            local -i i
            for (( i=1; i < ${#stmt[@]}; i++ )); do
                local -i var_size=4
                stack_used+=var_size
                if (( stack_used > stack_max )); then
                    stack_max=stack_used
                fi
            done;;
        expr|return|nothing) ;;
        *)  fail "TODO(measure_stack): ${stmt[0]}";;
    esac
}

emit_function() {
    local fname="$1"
    local -i node=${functions[$fname]}

    local -i stack_max=0
    local -i stack_used=0

    measure_stack $node

    echo "$fname has $stack_max bytes of local variables"

    if (( stack_max % STACK_ALIGNMENT != 0 )); then
        stack_max+=$((16 - stack_max % STACK_ALIGNMENT))
    fi

    echo "rounding up to $stack_max"

    local -i pos
    binlength pos "${sections[.text]}"
    symbol_sections["$fname"]=.text
    symbol_offsets["$fname"]=$pos

    code=""
    push_reg $RBP
    movq_reg_reg $RBP $RSP

    if (( stack_max )); then
        subq_reg_imm $RSP $stack_max
    fi

    # name -> offset from rbp
    local -A varmap=()
    # name -> declaring token (the ones that can be shadowed are not included)
    local -A vars_in_block=()

    emit_statement $node

    # by default, main should return 0
    if [[ "$fname" == "main" ]]; then
        xor_reg_reg $EAX $EAX
    fi

    leave
    ret

    sections[.text]+="$code"
}

emit_declare_var() {
    local name="$1" pos="$2"
    if [ -n "${vars_in_block[$name]-}" ]; then
        error "redefinition of \`$name\`"
        show_token ${vars_in_block[$name]} "\`$name\` first defined here"
        show_token $pos "\`$name\` redefined here"
        end_diagnostic
    fi

    vars_in_block[$name]=$pos
    local -i var_size=4
    local -i stack_offset=$stack_used
    stack_used+=var_size
    varmap[$name]=$((stack_offset - stack_max))

    if (( stack_offset >= stack_max )); then
        internal_error "insufficient stack frame allocated"
        show_token $pos "stack offset $stack_offset with stack frame $stack_max"
        end_diagnostic
        exit 1
    fi
}

check_var_exists() {
    local name="$1" pos="$2"
    if [ -z "${varmap[$name]-}" ]; then
        error "cannot find value \`$name\` in this scope"
        show_token $pos "not found in this scope"
        end_diagnostic
        return 1
    fi
}

emit_var_read() {
    local name="$1" pos="$2" reg="$3"
    check_var_exists "$name" "$pos" || return
    mov_reg_rbpoff "$reg" "${varmap[$name]}"
}

emit_var_write() {
    local name="$1" pos="$2" reg="$3"
    check_var_exists "$name" "$pos" || return
    mov_rbpoff_reg "${varmap[$name]}" "$reg"
}

emit_lvalue_write() {
    local lvalue="$1" reg="$2" assn_pos="$3"
    local -a expr=(${ast[lvalue]})
    case ${expr[0]} in
    var)
        local name="${expr[1]}" pos="${expr[2]}"
        emit_var_write "$name" "$pos" "$reg";;
    *)  error "invalid left-hand side of assignment"
        show_token $assn_pos
        end_diagnostic;;
    esac
}

emit_statement() {
    local -a stmt=(${ast[$1]})
    case ${stmt[0]} in
        declare)
            local -i i
            for (( i=1; i < ${#stmt[@]}; i++ )); do
                local node=${stmt[i]}
                local -a decl=(${ast[node]})
                local name=${decl[1]} pos=${decl[2]} value=${decl[3]-}
                emit_declare_var $name $pos
                if [ -n "$value" ]; then
                    emit_expr $value
                    emit_var_write $name $pos $EAX
                fi
            done;;
        compound)
            # allow shadowing
            local -i stack_used=$stack_used
            local -A vars_in_block=()

            local -i i
            for (( i=1; i < ${#stmt[@]}; i++ )); do
                emit_statement ${stmt[i]}
            done;;
        if)
            nest
                if [ -n "${stmt[3]-}" ]; then
                    emit_statement ${stmt[3]}
                fi
            unnest; local else="$res" else_len=$reslen

            nest
                emit_statement ${stmt[2]}
                jmp_forward $else_len
            unnest; local then="$res" then_len=$reslen

            emit_expr ${stmt[1]}
            test_reg_reg $EAX $EAX
            jcc_forward $CC_Z $then_len
            code+="$then$else";;
        expr)
            emit_expr ${stmt[1]};;
        return)
            emit_expr ${stmt[1]}
            leave
            ret;;
        nothing) ;;
        *)
            fail "TODO(emit_statement): ${stmt[@]}";;
    esac
}

cc_to_reg() {
    local cc="$1" reg="$2"
    setcc_reg $cc $reg
    movzxb_reg_reg $reg $reg
}

# emits code that puts the result in EAX
emit_expr() {
    local -a expr=(${ast[$1]})
    case ${expr[0]} in
        literal)
            mov_reg_imm $EAX ${expr[1]};;
        var)
            local name="${expr[1]}" pos="${expr[2]}"
            emit_var_read $name $pos $EAX;;
        assn)
            emit_expr ${expr[2]}
            emit_lvalue_write ${expr[1]} $EAX ${expr[3]};;
        bnot)
            emit_expr ${expr[1]}
            not_reg $EAX;;
        negate)
            emit_expr ${expr[1]}
            neg_reg $EAX;;
        unary_plus)
            emit_expr ${expr[1]};;
        add)
            emit_expr ${expr[1]}
            push_reg $EAX
            emit_expr ${expr[2]}
            pop_reg $ECX
            add_reg_reg $EAX $ECX;;
        sub)
            emit_expr ${expr[2]}
            push_reg $EAX
            emit_expr ${expr[1]}
            pop_reg $ECX
            sub_reg_reg $EAX $ECX;;
        xor)
            emit_expr ${expr[2]}
            push_reg $EAX
            emit_expr ${expr[1]}
            pop_reg $ECX
            xor_reg_reg $EAX $ECX;;
        band)
            emit_expr ${expr[2]}
            push_reg $EAX
            emit_expr ${expr[1]}
            pop_reg $ECX
            and_reg_reg $EAX $ECX;;
        bor)
            emit_expr ${expr[2]}
            push_reg $EAX
            emit_expr ${expr[1]}
            pop_reg $ECX
            or_reg_reg $EAX $ECX;;
        shl)
            emit_expr ${expr[2]}
            push_reg $EAX
            emit_expr ${expr[1]}
            pop_reg $ECX
            shl_reg_cl $EAX;;
        shr)
            emit_expr ${expr[2]}
            push_reg $EAX
            emit_expr ${expr[1]}
            pop_reg $ECX
            sar_reg_cl $EAX;;
        mul)
            emit_expr ${expr[2]}
            push_reg $EAX
            emit_expr ${expr[1]}
            pop_reg $ECX
            imul_reg_reg $EAX 1;;
        div)
            emit_expr ${expr[2]}
            push_reg $EAX
            emit_expr ${expr[1]}
            pop_reg $ECX
            cdq
            idiv_reg $ECX;;
        mod)
            emit_expr ${expr[2]}
            push_reg $EAX
            emit_expr ${expr[1]}
            pop_reg $ECX
            cdq
            idiv_reg $ECX
            mov_reg_reg $EAX $EDX;;
        eq)
            emit_expr ${expr[2]}
            push_reg $EAX
            emit_expr ${expr[1]}
            pop_reg $ECX
            cmp_reg_reg $EAX $ECX
            cc_to_reg $CC_E $EAX;;
        noteq)
            emit_expr ${expr[2]}
            push_reg $EAX
            emit_expr ${expr[1]}
            pop_reg $ECX
            cmp_reg_reg $EAX $ECX
            cc_to_reg $CC_NE $EAX;;
        lt)
            emit_expr ${expr[2]}
            push_reg $EAX
            emit_expr ${expr[1]}
            pop_reg $ECX
            cmp_reg_reg $EAX $ECX
            cc_to_reg $CC_L $EAX;;
        le)
            emit_expr ${expr[2]}
            push_reg $EAX
            emit_expr ${expr[1]}
            pop_reg $ECX
            cmp_reg_reg $EAX $ECX
            cc_to_reg $CC_LE $EAX;;
        gt)
            emit_expr ${expr[2]}
            push_reg $EAX
            emit_expr ${expr[1]}
            pop_reg $ECX
            cmp_reg_reg $EAX $ECX
            cc_to_reg $CC_G $EAX;;
        ge)
            emit_expr ${expr[2]}
            push_reg $EAX
            emit_expr ${expr[1]}
            pop_reg $ECX
            cmp_reg_reg $EAX $ECX
            cc_to_reg $CC_GE $EAX;;
        lnot)
            emit_expr ${expr[1]}
            test_reg_reg $EAX $EAX
            cc_to_reg $CC_Z $EAX;;
        land)
            nest
                emit_expr ${expr[2]}
                test_reg_reg $EAX $EAX
            unnest; local rhs="$res" rhs_len=$reslen

            emit_expr ${expr[1]}
            test_reg_reg $EAX $EAX
            jcc_forward $CC_Z $rhs_len
            code+="$rhs"
            cc_to_reg $CC_NZ $EAX;;
        lor)
            nest
                emit_expr ${expr[2]}
                test_reg_reg $EAX $EAX
            unnest; local rhs="$res" rhs_len=$reslen

            emit_expr ${expr[1]}
            test_reg_reg $EAX $EAX
            jcc_forward $CC_NZ $rhs_len
            code+="$rhs"
            cc_to_reg $CC_NZ $EAX;;
        ternary)
            nest
                emit_expr ${expr[3]}
            unnest; local no="$res" no_len=$reslen

            nest
                emit_expr ${expr[2]}
                jmp_forward $no_len
            unnest; local yes="$res" yes_len=$reslen

            emit_expr ${expr[1]}
            test_reg_reg $EAX $EAX
            jcc_forward $CC_Z $yes_len
            code+="$yes$no";;
        *)
            fail "TODO(emit_expr): ${expr[@]}";;
    esac
}
