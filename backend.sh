EAX=0
ECX=1
EDX=2
EBX=3

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

emit_function() {
    local fname="$1"

    local -i pos
    binlength pos "${sections[.text]}"
    symbol_sections["$fname"]=.text
    symbol_offsets["$fname"]=$pos

    local code=""
    local -i node=${functions[$fname]}
    emit_statement code $node
    ret code

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
            ret "$out";;
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
