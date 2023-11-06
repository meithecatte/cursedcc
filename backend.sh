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

modrm_reg() {
    # reg - register field
    # rm - r/m field (register index)
    local out="$1" reg="$2" rm="$3"
    p8 "$out" $((0xc0 + 8 * reg + rm))
}

modrm_rbpoff() {
    local out="$1" reg="$2" offset="$3"
    if (( -128 <= offset && offset <= 127 )); then
        p8 "$out" $((0x45 + 8 * reg))
        p8 "$out" $offset
    else
        p8 "$out" $((0x85 + 8 * reg))
        p32 "$out" $offset
    fi
}

leave() {
    local -n out="$1"
    out+="\xc9"
}

ret() {
    local -n out="$1"
    out+="\xc3"
}

mov_reg_imm() {
    local out="$1" reg="$2" imm="$3"
    p8 "$out" $((0xb8 + reg))
    p32 "$out" "$imm"
}

mov_reg_reg() {
    local -n out="$1"
    local dst="$2" src="$3"
    out+="\x89"
    modrm_reg "$1" "$src" "$dst"
}

mov_rbpoff_reg() {
    local -n out="$1"
    local offset="$2" src="$3"
    out+="\x89"
    modrm_rbpoff "$1" "$src" "$offset"
}

mov_reg_rbpoff() {
    local -n out="$1"
    local dst="$2" offset="$3"
    out+="\x8b"
    modrm_rbpoff "$1" "$dst" "$offset"
}

movq_reg_reg() {
    local -n out="$1"
    local dst="$2" src="$3"
    out+="\x48\x89"
    modrm_reg "$1" "$src" "$dst"
}

not_reg() {
    local -n out="$1"
    local reg="$2"
    out+="\xf7"
    modrm_reg "$1" 2 "$reg"
}

neg_reg() {
    local -n out="$1"
    local reg="$2"
    out+="\xf7"
    modrm_reg "$1" 3 "$reg"
}

shl_reg_cl() {
    local -n out="$1"
    local reg="$2"
    out+="\xd3"
    modrm_reg "$1" 4 "$reg"
}

shr_reg_cl() {
    local -n out="$1"
    local reg="$2"
    out+="\xd3"
    modrm_reg "$1" 5 "$reg"
}

sar_reg_cl() {
    local -n out="$1"
    local reg="$2"
    out+="\xd3"
    modrm_reg "$1" 7 "$reg"
}

push_reg() {
    local out="$1" reg="$2"
    p8 "$1" $((0x50 + reg))
}

pop_reg() {
    local out="$1" reg="$2"
    p8 "$1" $((0x58 + reg))
}

add_reg_reg() {
    local -n out="$1"
    local dst="$2" src="$3"
    out+="\x01"
    modrm_reg "$1" "$src" "$dst"
}

or_reg_reg() {
    local -n out="$1"
    local dst="$2" src="$3"
    out+="\x09"
    modrm_reg "$1" "$src" "$dst"
}

and_reg_reg() {
    local -n out="$1"
    local dst="$2" src="$3"
    out+="\x21"
    modrm_reg "$1" "$src" "$dst"
}

sub_reg_reg() {
    local -n out="$1"
    local dst="$2" src="$3"
    out+="\x29"
    modrm_reg "$1" "$src" "$dst"
}

subq_reg_imm() {
    local -n out="$1"
    local dst="$2" imm="$3"
    if (( -128 <= imm && imm <= 127 )); then
        out+="\x48\x83"
        modrm_reg "$1" 5 "$dst"
        p8 "$1" "$imm"
    else
        out+="\x48\x81"
        modrm_reg "$1" 5 "$dst"
        p32 "$1" "$imm"
    fi
}

xor_reg_reg() {
    local -n out="$1"
    local dst="$2" src="$3"
    out+="\x31"
    modrm_reg "$1" "$src" "$dst"
}

cmp_reg_reg() {
    local -n out="$1"
    local dst="$2" src="$3"
    out+="\x39"
    modrm_reg "$1" "$src" "$dst"
}

test_reg_reg() {
    local -n out="$1"
    local dst="$2" src="$3"
    out+="\x85"
    modrm_reg "$1" "$src" "$dst"
}

imul_reg_reg() {
    local -n out="$1"
    local dst="$2" src="$3"
    out+="\x0f\xaf"
    modrm_reg "$1" "$dst" "$src"
}

cdq() {
    local -n out="$1"
    out+="\x99"
}

idiv_reg() {
    local -n out="$1"
    local reg="$2"
    out+="\xf7"
    modrm_reg "$1" 7 "$reg"
}

movzxb_reg_reg() {
    local -n out="$1"
    local dst="$2" src="$3"
    out+="\x0f\xb6"
    modrm_reg "$1" "$src" "$dst"
}

setcc_reg() {
    local -n out="$1"
    local cc="$2" dst="$3"
    out+="\x0f"
    p8 "$1" $((0x90 + cc))
    modrm_reg "$1" 0 "$dst"
}

jcc_forward() {
    local -n out="$1"
    local cc="$2" dist="$3"
    if (( dist < 0x80 )); then
        p8 "$1" $((0x70 + cc))
        p8 "$1" $dist
    else
        out+="\x0f"
        p8 "$1" $((0x80 + cc))
        p32 "$1" $dist
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
                measure_stack "${stmt[i]}"
            done;;
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

    local code=""
    push_reg code $RBP
    movq_reg_reg code $RBP $RSP

    if (( stack_max )); then
        subq_reg_imm code $RSP $stack_max
    fi

    # name -> offset from rbp
    local -A varmap=()
    # name -> declaring token (the ones that can be shadowed are not included)
    local -A vars_in_block=()

    emit_statement code $node

    # by default, main should return 0
    if [[ "$fname" == "main" ]]; then
        xor_reg_reg code $EAX $EAX
    fi

    leave code
    ret code

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
    local out="$1" name="$2" pos="$3" reg="$4"
    check_var_exists "$name" "$pos" || return
    mov_reg_rbpoff "$out" "$reg" "${varmap[$name]}"
}

emit_var_write() {
    local out="$1" name="$2" pos="$3" reg="$4"
    check_var_exists "$name" "$pos" || return
    mov_rbpoff_reg "$out" "${varmap[$name]}" "$reg"
}

emit_lvalue_write() {
    local out="$1" lvalue="$2" reg="$3"
    local -a expr=(${ast[lvalue]})
    case ${expr[0]} in
    var)
        local name="${expr[1]}" pos="${expr[2]}"
        emit_var_write "$out" "$name" "$pos" "$reg";;
    *)  error "invalid left-hand side of assignment"
        # TODO: location tracking
        end_diagnostic;;
    esac
}

emit_statement() {
    local out="$1"
    local node="$2"
    local -a stmt=(${ast[node]})
    case ${stmt[0]} in
        declare)
            local -i i
            for (( i=1; i < ${#stmt[@]}; i++ )); do
                local node=${stmt[i]}
                local -a decl=(${ast[node]})
                local name=${decl[1]} pos=${decl[2]} value=${decl[3]-}
                emit_declare_var $name $pos
                if [ -n "$value" ]; then
                    emit_expr $out $value
                    emit_var_write "$out" "$name" "$pos" $EAX
                fi
            done;;
        compound)
            # allow shadowing
            local -i stack_used=$stack_used
            local -A vars_in_block=()

            local -i i
            for (( i=1; i < ${#stmt[@]}; i++ )); do
                emit_statement "$out" "${stmt[i]}"
            done;;
        expr)
            emit_expr "$out" "${stmt[1]}";;
        return)
            emit_expr "$out" "${stmt[1]}"
            leave "$out"
            ret "$out";;
        nothing) ;;
        *)
            fail "TODO(emit_statement): ${stmt[@]}";;
    esac
}

cc_to_reg() {
    local out="$1" cc="$2" reg="$3"
    setcc_reg $out $cc $reg
    movzxb_reg_reg $out $reg $reg
}

# emits code that puts the result in EAX
emit_expr() {
    local out="$1"
    local node="$2"
    local -a expr=(${ast[node]})
    case ${expr[0]} in
        literal)
            mov_reg_imm "$out" $EAX ${expr[1]};;
        var)
            local name="${expr[1]}" pos="${expr[2]}"
            emit_var_read "$out" "$name" "$pos" $EAX;;
        assn)
            emit_expr "$out" ${expr[2]}
            emit_lvalue_write "$out" ${expr[1]} $EAX;;
        bnot)
            emit_expr "$out" ${expr[1]}
            not_reg "$out" $EAX;;
        negate)
            emit_expr "$out" ${expr[1]}
            neg_reg "$out" $EAX;;
        unary_plus)
            emit_expr "$out" ${expr[1]};;
        add)
            emit_expr "$out" ${expr[1]}
            push_reg "$out" $EAX
            emit_expr "$out" ${expr[2]}
            pop_reg "$out" $ECX
            add_reg_reg "$out" $EAX $ECX;;
        sub)
            emit_expr "$out" ${expr[2]}
            push_reg "$out" $EAX
            emit_expr "$out" ${expr[1]}
            pop_reg "$out" $ECX
            sub_reg_reg "$out" $EAX $ECX;;
        xor)
            emit_expr "$out" ${expr[2]}
            push_reg "$out" $EAX
            emit_expr "$out" ${expr[1]}
            pop_reg "$out" $ECX
            xor_reg_reg "$out" $EAX $ECX;;
        band)
            emit_expr "$out" ${expr[2]}
            push_reg "$out" $EAX
            emit_expr "$out" ${expr[1]}
            pop_reg "$out" $ECX
            and_reg_reg "$out" $EAX $ECX;;
        bor)
            emit_expr "$out" ${expr[2]}
            push_reg "$out" $EAX
            emit_expr "$out" ${expr[1]}
            pop_reg "$out" $ECX
            or_reg_reg "$out" $EAX $ECX;;
        shl)
            emit_expr "$out" ${expr[2]}
            push_reg "$out" $EAX
            emit_expr "$out" ${expr[1]}
            pop_reg "$out" $ECX
            shl_reg_cl "$out" $EAX;;
        shr)
            emit_expr "$out" ${expr[2]}
            push_reg "$out" $EAX
            emit_expr "$out" ${expr[1]}
            pop_reg "$out" $ECX
            sar_reg_cl "$out" $EAX;;
        mul)
            emit_expr "$out" ${expr[2]}
            push_reg "$out" $EAX
            emit_expr "$out" ${expr[1]}
            pop_reg "$out" $ECX
            imul_reg_reg "$out" $EAX 1;;
        div)
            emit_expr "$out" ${expr[2]}
            push_reg "$out" $EAX
            emit_expr "$out" ${expr[1]}
            pop_reg "$out" $ECX
            cdq "$out"
            idiv_reg "$out" $ECX;;
        mod)
            emit_expr "$out" ${expr[2]}
            push_reg "$out" $EAX
            emit_expr "$out" ${expr[1]}
            pop_reg "$out" $ECX
            cdq "$out"
            idiv_reg "$out" $ECX
            mov_reg_reg "$out" $EAX $EDX;;
        eq)
            emit_expr "$out" ${expr[2]}
            push_reg "$out" $EAX
            emit_expr "$out" ${expr[1]}
            pop_reg "$out" $ECX
            cmp_reg_reg "$out" $EAX $ECX
            cc_to_reg "$out" $CC_E $EAX;;
        noteq)
            emit_expr "$out" ${expr[2]}
            push_reg "$out" $EAX
            emit_expr "$out" ${expr[1]}
            pop_reg "$out" $ECX
            cmp_reg_reg "$out" $EAX $ECX
            cc_to_reg "$out" $CC_NE $EAX;;
        lt)
            emit_expr "$out" ${expr[2]}
            push_reg "$out" $EAX
            emit_expr "$out" ${expr[1]}
            pop_reg "$out" $ECX
            cmp_reg_reg "$out" $EAX $ECX
            cc_to_reg "$out" $CC_L $EAX;;
        le)
            emit_expr "$out" ${expr[2]}
            push_reg "$out" $EAX
            emit_expr "$out" ${expr[1]}
            pop_reg "$out" $ECX
            cmp_reg_reg "$out" $EAX $ECX
            cc_to_reg "$out" $CC_LE $EAX;;
        gt)
            emit_expr "$out" ${expr[2]}
            push_reg "$out" $EAX
            emit_expr "$out" ${expr[1]}
            pop_reg "$out" $ECX
            cmp_reg_reg "$out" $EAX $ECX
            cc_to_reg "$out" $CC_G $EAX;;
        ge)
            emit_expr "$out" ${expr[2]}
            push_reg "$out" $EAX
            emit_expr "$out" ${expr[1]}
            pop_reg "$out" $ECX
            cmp_reg_reg "$out" $EAX $ECX
            cc_to_reg "$out" $CC_GE $EAX;;
        lnot)
            emit_expr "$out" ${expr[1]}
            test_reg_reg "$out" $EAX $EAX
            cc_to_reg "$out" $CC_Z $EAX;;
        land)
            local short_circuit=""
            emit_expr short_circuit ${expr[2]}
            test_reg_reg short_circuit $EAX $EAX
            local -i short_circuit_len
            binlength short_circuit_len "$short_circuit"

            emit_expr "$out" ${expr[1]}
            test_reg_reg "$out" $EAX $EAX
            jcc_forward "$out" $CC_Z $short_circuit_len
            local -n vout="$out"
            vout+="$short_circuit"
            cc_to_reg "$out" $CC_NZ $EAX;;
        lor)
            local short_circuit=""
            emit_expr short_circuit ${expr[2]}
            test_reg_reg short_circuit $EAX $EAX
            local -i short_circuit_len
            binlength short_circuit_len "$short_circuit"

            emit_expr "$out" ${expr[1]}
            test_reg_reg "$out" $EAX $EAX
            jcc_forward "$out" $CC_NZ $short_circuit_len
            local -n vout="$out"
            vout+="$short_circuit"
            cc_to_reg "$out" $CC_NZ $EAX;;
        *)
            fail "TODO(emit_expr): ${expr[@]}";;
    esac
}
