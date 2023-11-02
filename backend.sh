x64_ret() {
    local -n out="$1"
    out+="\xc3"
}

x64_mov_reg_imm() {
    local out="$1" reg="$2" imm="$3"
    p8 "$out" $((0xb8 + reg))
    p32 "$out" "$imm"
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
            echo "TODO(emit_statement): ${stmt[@]}";;
    esac
}

emit_expr() {
    local out="$1"
    local node="$2"
    local -a expr=(${ast[node]})
    case ${expr[0]} in
        literal)
            x64_mov_reg_imm code 0 ${expr[1]};;
        *)
            echo "TODO(emit_expr): ${expr[@]}";;
    esac
}
