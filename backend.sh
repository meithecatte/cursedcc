EAX=0
ECX=1
EDX=2
EBX=3

CC_E=4
CC_NE=5
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

x64_ret() {
    local -n out="$1"
    out+="\xc3"
}

x64_mov_reg_imm() {
    local out="$1" reg="$2" imm="$3"
    p8 "$out" $((0xb8 + reg))
    p32 "$out" "$imm"
}

x64_mov_reg_reg() {
    local -n out="$1"
    local dst="$2" src="$3"
    out+="\x89"
    modrm_reg "$1" "$src" "$dst"
}

x64_not_reg() {
    local -n out="$1"
    local reg="$2"
    out+="\xf7"
    modrm_reg "$1" 2 "$reg"
}

x64_neg_reg() {
    local -n out="$1"
    local reg="$2"
    out+="\xf7"
    modrm_reg "$1" 3 "$reg"
}

x64_shl_reg_cl() {
    local -n out="$1"
    local reg="$2"
    out+="\xd3"
    modrm_reg "$1" 4 "$reg"
}

x64_shr_reg_cl() {
    local -n out="$1"
    local reg="$2"
    out+="\xd3"
    modrm_reg "$1" 5 "$reg"
}

x64_sar_reg_cl() {
    local -n out="$1"
    local reg="$2"
    out+="\xd3"
    modrm_reg "$1" 7 "$reg"
}

x64_push_reg() {
    local out="$1" reg="$2"
    p8 "$1" $((0x50 + reg))
}

x64_pop_reg() {
    local out="$1" reg="$2"
    p8 "$1" $((0x58 + reg))
}

x64_add_reg_reg() {
    local -n out="$1"
    local dst="$2" src="$3"
    out+="\x01"
    modrm_reg "$1" "$src" "$dst"
}

x64_or_reg_reg() {
    local -n out="$1"
    local dst="$2" src="$3"
    out+="\x09"
    modrm_reg "$1" "$src" "$dst"
}

x64_and_reg_reg() {
    local -n out="$1"
    local dst="$2" src="$3"
    out+="\x21"
    modrm_reg "$1" "$src" "$dst"
}

x64_sub_reg_reg() {
    local -n out="$1"
    local dst="$2" src="$3"
    out+="\x29"
    modrm_reg "$1" "$src" "$dst"
}

x64_xor_reg_reg() {
    local -n out="$1"
    local dst="$2" src="$3"
    out+="\x31"
    modrm_reg "$1" "$src" "$dst"
}

x64_cmp_reg_reg() {
    local -n out="$1"
    local dst="$2" src="$3"
    out+="\x39"
    modrm_reg "$1" "$src" "$dst"
}

x64_test_reg_reg() {
    local -n out="$1"
    local dst="$2" src="$3"
    out+="\x85"
    modrm_reg "$1" "$src" "$dst"
}

x64_imul_reg_reg() {
    local -n out="$1"
    local dst="$2" src="$3"
    out+="\x0f\xaf"
    modrm_reg "$1" "$dst" "$src"
}

x64_cdq() {
    local -n out="$1"
    out+="\x99"
}

x64_idiv_reg() {
    local -n out="$1"
    local reg="$2"
    out+="\xf7"
    modrm_reg "$1" 7 "$reg"
}

x64_movzxb_reg_reg() {
    local -n out="$1"
    local dst="$2" src="$3"
    out+="\x0f\xb6"
    modrm_reg "$1" "$src" "$dst"
}

x64_setcc_reg() {
    local -n out="$1"
    local cc="$2" dst="$3"
    out+="\x0f"
    p8 "$1" $((0x90 + cc))
    modrm_reg "$1" 0 "$dst"
}

emit_function() {
    local fname="$1"

    local -i pos
    binlength pos "${sections[.text]}"
    symbol_sections["$fname"]=.text
    symbol_offsets["$fname"]=$pos

    local code=""
    local -i node=${functions[$fname]}
    emit_statement code $node
    x64_ret code

    sections[.text]+="$code"
}

emit_statement() {
    local out="$1"
    local node="$2"
    local -a stmt=(${ast[node]})
    case ${stmt[0]} in
        compound)
            local -i i
            for (( i=1; i < ${#stmt[@]}; i++ )); do
                emit_statement "$out" "${stmt[i]}"
            done;;
        return)
            emit_expr "$out" "${stmt[1]}"
            x64_ret "$out";;
        *)
            fail "TODO(emit_statement): ${stmt[@]}";;
    esac
}

cc_to_reg() {
    local out="$1" cc="$2" reg="$3"
    x64_setcc_reg $out $cc $reg
    x64_movzxb_reg_reg $out $reg $reg
}

# emits code that puts the result in EAX
emit_expr() {
    local out="$1"
    local node="$2"
    local -a expr=(${ast[node]})
    case ${expr[0]} in
        literal)
            x64_mov_reg_imm "$out" $EAX ${expr[1]};;
        bnot)
            emit_expr "$out" ${expr[1]}
            x64_not_reg "$out" $EAX;;
        negate)
            emit_expr "$out" ${expr[1]}
            x64_neg_reg "$out" $EAX;;
        unary_plus)
            emit_expr "$out" ${expr[1]};;
        add)
            emit_expr "$out" ${expr[1]}
            x64_push_reg "$out" $EAX
            emit_expr "$out" ${expr[2]}
            x64_pop_reg "$out" $ECX
            x64_add_reg_reg "$out" $EAX $ECX;;
        sub)
            emit_expr "$out" ${expr[2]}
            x64_push_reg "$out" $EAX
            emit_expr "$out" ${expr[1]}
            x64_pop_reg "$out" $ECX
            x64_sub_reg_reg "$out" $EAX $ECX;;
        xor)
            emit_expr "$out" ${expr[2]}
            x64_push_reg "$out" $EAX
            emit_expr "$out" ${expr[1]}
            x64_pop_reg "$out" $ECX
            x64_xor_reg_reg "$out" $EAX $ECX;;
        band)
            emit_expr "$out" ${expr[2]}
            x64_push_reg "$out" $EAX
            emit_expr "$out" ${expr[1]}
            x64_pop_reg "$out" $ECX
            x64_and_reg_reg "$out" $EAX $ECX;;
        bor)
            emit_expr "$out" ${expr[2]}
            x64_push_reg "$out" $EAX
            emit_expr "$out" ${expr[1]}
            x64_pop_reg "$out" $ECX
            x64_or_reg_reg "$out" $EAX $ECX;;
        shl)
            emit_expr "$out" ${expr[2]}
            x64_push_reg "$out" $EAX
            emit_expr "$out" ${expr[1]}
            x64_pop_reg "$out" $ECX
            x64_shl_reg_cl "$out" $EAX;;
        shr)
            emit_expr "$out" ${expr[2]}
            x64_push_reg "$out" $EAX
            emit_expr "$out" ${expr[1]}
            x64_pop_reg "$out" $ECX
            x64_sar_reg_cl "$out" $EAX;;
        mul)
            emit_expr "$out" ${expr[2]}
            x64_push_reg "$out" $EAX
            emit_expr "$out" ${expr[1]}
            x64_pop_reg "$out" $ECX
            x64_imul_reg_reg "$out" $EAX 1;;
        div)
            emit_expr "$out" ${expr[2]}
            x64_push_reg "$out" $EAX
            emit_expr "$out" ${expr[1]}
            x64_pop_reg "$out" $ECX
            x64_cdq "$out"
            x64_idiv_reg "$out" $ECX;;
        mod)
            emit_expr "$out" ${expr[2]}
            x64_push_reg "$out" $EAX
            emit_expr "$out" ${expr[1]}
            x64_pop_reg "$out" $ECX
            x64_cdq "$out"
            x64_idiv_reg "$out" $ECX
            x64_mov_reg_reg "$out" $EAX $EDX;;
        eq)
            emit_expr "$out" ${expr[2]}
            x64_push_reg "$out" $EAX
            emit_expr "$out" ${expr[1]}
            x64_pop_reg "$out" $ECX
            x64_cmp_reg_reg "$out" $EAX $ECX
            cc_to_reg "$out" $CC_E $EAX;;
        noteq)
            emit_expr "$out" ${expr[2]}
            x64_push_reg "$out" $EAX
            emit_expr "$out" ${expr[1]}
            x64_pop_reg "$out" $ECX
            x64_cmp_reg_reg "$out" $EAX $ECX
            cc_to_reg "$out" $CC_NE $EAX;;
        lt)
            emit_expr "$out" ${expr[2]}
            x64_push_reg "$out" $EAX
            emit_expr "$out" ${expr[1]}
            x64_pop_reg "$out" $ECX
            x64_cmp_reg_reg "$out" $EAX $ECX
            cc_to_reg "$out" $CC_L $EAX;;
        le)
            emit_expr "$out" ${expr[2]}
            x64_push_reg "$out" $EAX
            emit_expr "$out" ${expr[1]}
            x64_pop_reg "$out" $ECX
            x64_cmp_reg_reg "$out" $EAX $ECX
            cc_to_reg "$out" $CC_LE $EAX;;
        gt)
            emit_expr "$out" ${expr[2]}
            x64_push_reg "$out" $EAX
            emit_expr "$out" ${expr[1]}
            x64_pop_reg "$out" $ECX
            x64_cmp_reg_reg "$out" $EAX $ECX
            cc_to_reg "$out" $CC_G $EAX;;
        ge)
            emit_expr "$out" ${expr[2]}
            x64_push_reg "$out" $EAX
            emit_expr "$out" ${expr[1]}
            x64_pop_reg "$out" $ECX
            x64_cmp_reg_reg "$out" $EAX $ECX
            cc_to_reg "$out" $CC_GE $EAX;;
        lnot)
            emit_expr "$out" ${expr[1]}
            x64_test_reg_reg "$out" $EAX $EAX
            cc_to_reg "$out" $CC_E $EAX;;
        *)
            fail "TODO(emit_expr): ${expr[@]}";;
    esac
}
