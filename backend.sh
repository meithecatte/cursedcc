EAX=0
ECX=1
EDX=2
EBX=3

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
            x64_sub_reg_reg "$out" $EAX 1;;
        xor)
            emit_expr "$out" ${expr[2]}
            x64_push_reg "$out" $EAX
            emit_expr "$out" ${expr[1]}
            x64_pop_reg "$out" $ECX
            x64_xor_reg_reg "$out" $EAX 1;;
        band)
            emit_expr "$out" ${expr[2]}
            x64_push_reg "$out" $EAX
            emit_expr "$out" ${expr[1]}
            x64_pop_reg "$out" $ECX
            x64_and_reg_reg "$out" $EAX 1;;
        bor)
            emit_expr "$out" ${expr[2]}
            x64_push_reg "$out" $EAX
            emit_expr "$out" ${expr[1]}
            x64_pop_reg "$out" $ECX
            x64_or_reg_reg "$out" $EAX 1;;
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
        *)
            fail "TODO(emit_expr): ${expr[@]}";;
    esac
}
