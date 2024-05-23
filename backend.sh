STACK_ALIGNMENT=16

EAX=0
ECX=1
EDX=2
EBX=3
ESP=4; RSP=4
EBP=5; RBP=5
ESI=6
EDI=7
R8=8
R9=9

declare abi_regs=($EDI $ESI $EDX $ECX $R8 $R9)

CC_E=4
CC_Z=4
CC_NE=5
CC_NZ=5
CC_L=12
CC_GE=13
CC_LE=14
CC_G=15

# NOTE: the label resolver assumes that all bytes in "$code" are encoded
# as four characters (backslash, x, and two hexdigits). So don't get clever
# with octal or \n or whatever else.
declare code=""
declare -a relocs=()

# rex r b w
rex() {
    local r=$1 b=$2 w=${3-0}
    local -i byte=0x40
    (( w )) && (( byte |= 8 ))
    (( r >= 8 )) && (( byte |= 4 ))
    (( b >= 8 )) && (( byte |= 1 ))
    if (( byte != 0x40 )); then
        p8 code $byte
    fi
}

op_modrm_reg() {
    # reg - register field
    # rm - r/m field (register index)
    # wide - if nonzero, 64-bit data
    local op="$1" reg="$2" rm="$3" wide="${4-0}"
    rex $reg $rm $wide
    code+="$op"
    p8 code $((0xc0 + 8 * (reg & 7) + (rm & 7)))
}

op_modrm_rbpoff() {
    local op="$1" reg="$2" offset="$3"
    rex $reg 0
    code+="$op"
    if (( -128 <= offset && offset <= 127 )); then
        p8 code $((0x45 + 8 * (reg & 7)))
        p8 code $offset
    else
        p8 code $((0x85 + 8 * (reg & 7)))
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
    (( reg < 8 )) || fail "TODO: load immediate into high reg"
    p8 code $((0xb8 + reg))
    p32 code "$imm"
}

mov_reg_reg() {
    local dst="$1" src="$2"
    op_modrm_reg "\x89" "$src" "$dst"
}

mov_rbpoff_reg() {
    local offset="$1" src="$2"
    op_modrm_rbpoff "\x89" "$src" "$offset"
}

mov_reg_rbpoff() {
    local dst="$1" offset="$2"
    op_modrm_rbpoff "\x8b" "$dst" "$offset"
}

movq_reg_reg() {
    local dst="$1" src="$2"
    op_modrm_reg "\x89" "$src" "$dst" 1
}

not_reg() {
    local reg="$1"
    op_modrm_reg "\xf7" 2 "$reg"
}

neg_reg() {
    local reg="$1"
    op_modrm_reg "\xf7" 3 "$reg"
}

shl_reg_cl() {
    local reg="$1"
    op_modrm_reg "\xd3" 4 "$reg"
}

shr_reg_cl() {
    local reg="$1"
    op_modrm_reg "\xd3" 5 "$reg"
}

sar_reg_cl() {
    local reg="$1"
    op_modrm_reg "\xd3" 7 "$reg"
}

push_reg() {
    local reg="$1"
    rex 0 $reg
    p8 code $((0x50 + (reg & 7)))
}

pop_reg() {
    local reg="$1"
    rex 0 $reg
    p8 code $((0x58 + (reg & 7)))
}

add_reg_reg() {
    local dst="$1" src="$2"
    op_modrm_reg "\x01" "$src" "$dst"
}

or_reg_reg() {
    local dst="$1" src="$2"
    op_modrm_reg "\x09" "$src" "$dst"
}

and_reg_reg() {
    local dst="$1" src="$2"
    op_modrm_reg "\x21" "$src" "$dst"
}

sub_reg_reg() {
    local dst="$1" src="$2"
    op_modrm_reg "\x29" "$src" "$dst"
}

subq_reg_imm() {
    local dst="$1" imm="$2"
    if (( -128 <= imm && imm <= 127 )); then
        op_modrm_reg "\x83" 5 "$dst" 1
        p8 code "$imm"
    else
        op_modrm_reg "\x81" 5 "$dst" 1
        p32 code "$imm"
    fi
}

xor_reg_reg() {
    local dst="$1" src="$2"
    op_modrm_reg "\x31" "$src" "$dst"
}

cmp_reg_reg() {
    local dst="$1" src="$2"
    op_modrm_reg "\x39" "$src" "$dst"
}

test_reg_reg() {
    local dst="$1" src="$2"
    op_modrm_reg "\x85" "$src" "$dst"
}

imul_reg_reg() {
    local dst="$1" src="$2"
    op_modrm_reg "\x0f\xaf" "$dst" "$src"
}

cdq() {
    code+="\x99"
}

idiv_reg() {
    local reg="$1"
    op_modrm_reg "\xf7" 7 "$reg"
}

movzxb_reg_reg() {
    local dst="$1" src="$2"
    op_modrm_reg "\x0f\xb6" "$src" "$dst"
}

setcc_reg() {
    local cc="$1" dst="$2"
    local opcode="\x0f"
    p8 opcode $((0x90 + cc))
    op_modrm_reg "$opcode" 0 "$dst"
}

# jmp label
jmp() {
    jump "$1"
}

# jmp cc label
jcc() {
    jump "$2" "$1"
}

# call symbol
call_symbol() {
    local -i pos
    code+="\xe8"
    binlength pos "$code"
    relocs+=(".text $((function_pos + pos)) $1 $R_X86_64_PC32 -4")
    p32 code 0
}

# AST traversal starts here
# measure_params_stack params
measure_params_stack() {
    local -a params=(${ast[$1]})
    for param_id in "${params[@]:1}"; do
        local -a param=(${ast[param_id]})
        if (( ${#param[@]} < 3 )) && [ "${param[1]}" != void ]; then
            error "missing name for parameter"
            show_node $param_id "parameter name omitted"
            end_diagnostic
            continue
        fi

        if [ "${param[1]}" == void ]; then
            if (( ${#param[@]} == 3 )); then
                error "invalid type for parameter"
                show_node $param_id "parameter cannot have type \`void\`"
                end_diagnostic
                continue
            elif (( ${#params[@]} != 2 )); then
                error "\`void\` must be the only parameter"
                show_node $param_id "\`void\` must be the only parameter"
                end_diagnostic
                continue
            fi
        else
            local -i var_size=4
            stack_used+=$var_size
        fi
    done
}

# emit_prologue params
emit_prologue() {
    local -a params=(${ast[$1]}) param_pos=(${ast_pos[$1]})
    local -i i=0
    for param_id in "${params[@]:1}"; do
        local -a param=(${ast[param_id]})
        if [ "${param[1]}" == void ]; then
            continue
        fi

        local name="${param[2]}" pos="${param_pos[1]}"
        if (( i < ${#abi_regs[@]} )); then
            emit_declare_var "$name" "$pos"
            emit_var_write "$name" "$pos" "${abi_regs[i]}"
        else
            check_declare_var "$name" "$pos"
            varmap["$name"]=$((8 * (i - 6) + 16))
        fi
        i+=1
    done
}

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
        label)
            local label_name=${stmt[1]}
            local labeled_stmt=${stmt[2]}

            if [ -n "${user_labels[$label_name]-}" ]; then
                error "duplicate label \`$label_name\`"
                show_node ${user_labels[$label_name]} "label first defined here"
                show_node $1 "label redefined here"
                end_diagnostic
            else
                user_labels[$label_name]=$1
            fi

            measure_stack $labeled_stmt;;
        if)
            measure_stack ${stmt[2]}
            if [ -n "${stmt[3]-}" ]; then
                measure_stack ${stmt[3]}
            fi;;
        while)
            measure_stack ${stmt[2]};;
        dowhile)
            measure_stack ${stmt[1]};;
        for)
            # NOTE: for loops are partially desugared in the parser to move
            # the initializing clause to a compound block surrounding
            # the for loop node. As such, we don't need to do anything about
            # the possible allocation of the loop's control variable.
            measure_stack ${stmt[3]};;
        declare)
            local -i i
            for (( i=1; i < ${#stmt[@]}; i++ )); do
                local -i var_size=4
                stack_used+=var_size
                if (( stack_used > stack_max )); then
                    stack_max=stack_used
                fi
            done;;
        expr|return|nothing|goto|continue|break) ;;
        *)  fail "TODO(measure_stack): ${stmt[0]}";;
    esac
}

emit_function() {
    local fname="$1"
    local function_def=(${functions[$fname]})
    local -i node=${function_def[0]}
    local params=${function_def[2]}

    local -i stack_used=0
    measure_params_stack $params
    local -i stack_max=$stack_used

    # Maps goto-labels to the positions at which they were defined
    local -iA user_labels=()

    measure_stack $node
    stack_used=0

    echo "$fname has $stack_max bytes of local variables"

    if (( stack_max % STACK_ALIGNMENT != 0 )); then
        stack_max+=$((16 - stack_max % STACK_ALIGNMENT))
    fi

    echo "rounding up to $stack_max"

    clear_labels
    local -i function_pos label_counter=0
    binlength function_pos "${sections[.text]}"
    symbol_sections["$fname"]=.text
    symbol_offsets["$fname"]=$function_pos

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
    emit_prologue $params

    emit_statement $node

    # by default, main should return 0
    if [[ "$fname" == "main" ]]; then
        xor_reg_reg $EAX $EAX
    fi

    label epilogue
    leave
    ret

    resolve_jumps
    sections[.text]+="$code"
}

check_declare_var() {
    local name="$1" pos="$2"
    if [ -n "${vars_in_block[$name]-}" ]; then
        error "redefinition of \`$name\`"
        show_token ${vars_in_block[$name]} "\`$name\` first defined here"
        show_token $pos "\`$name\` redefined here"
        end_diagnostic
    fi

    vars_in_block[$name]=$pos
}

# emit_declare_var name pos
emit_declare_var() {
    local name="$1" pos="$2"
    check_declare_var "$name" "$pos"

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
        label)
            label user_${stmt[1]}
            emit_statement ${stmt[2]};;
        compound)
            # allow shadowing
            local -i stack_used=$stack_used
            local -A vars_in_block=()
            local varmap_def=$(declare -p varmap)
            local -A varmap="${varmap_def#*=}"

            local -i i
            for (( i=1; i < ${#stmt[@]}; i++ )); do
                emit_statement ${stmt[i]}
            done;;
        if)
            local -i x=$label_counter
            label_counter+=1

            emit_expr ${stmt[1]}
            test_reg_reg $EAX $EAX
            jcc $CC_Z else$x

            emit_statement ${stmt[2]}
            jmp fi$x

            label else$x
            if [ -n "${stmt[3]-}" ]; then
                emit_statement ${stmt[3]}
            fi
            label fi$x;;
        while)
            local -i x=$label_counter
            label_counter+=1

            local innermost_continue=continue$x innermost_break=break$x
            label continue$x
            emit_expr ${stmt[1]}
            test_reg_reg $EAX $EAX
            jcc $CC_Z break$x

            emit_statement ${stmt[2]}
            jmp continue$x

            label break$x;;
        dowhile)
            local -i x=$label_counter
            label_counter+=1

            local innermost_continue=continue$x innermost_break=break$x
            label loop$x
            emit_statement ${stmt[1]}

            label continue$x
            emit_expr ${stmt[2]}
            test_reg_reg $EAX $EAX
            jcc $CC_NZ loop$x

            label break$x;;
        for)
            local -i x=$label_counter
            label_counter+=1

            local innermost_continue=continue$x innermost_break=break$x

            label loop$x
            emit_expr ${stmt[1]}
            test_reg_reg $EAX $EAX
            jcc $CC_Z break$x

            emit_statement ${stmt[3]}
            label continue$x

            emit_statement ${stmt[2]}
            jmp loop$x

            label break$x;;

        continue)
            if [ -z "${innermost_continue-}" ]; then
                error "\`continue\` can only be used within a loop"
                show_node $1 "not in a loop"
                end_diagnostic
            else
                jmp $innermost_continue
            fi;;
        break)
            if [ -z "${innermost_break-}" ]; then
                error "\`break\` can only be used within a loop or a switch"
                show_node $1 "not in a loop or a switch"
                end_diagnostic
            else
                jmp $innermost_break
            fi;;
        goto)
            local label_name=${stmt[1]}
            local pos=${stmt[2]}

            if [ -z "${user_labels[$label_name]-}" ]; then
                error "undeclared label \`$label_name\`"
                show_token $pos "no such label"
                end_diagnostic
            fi

            jmp user_$label_name;;
        expr)
            emit_expr ${stmt[1]};;
        return)
            emit_expr ${stmt[1]}
            jmp epilogue;;
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
    local -a expr=(${ast[$1]}) pos=(${ast_pos[$1]})
    case ${expr[0]} in
        literal)
            mov_reg_imm $EAX ${expr[1]};;
        var)
            local name="${expr[1]}"
            emit_var_read $name ${pos[0]} $EAX;;
        call)
            local lhs="${expr[1]}"
            local -a call_target=(${ast[lhs]})
            if [ "${call_target[0]}" != "var" ]; then
                error "indirect calls are not supported"
                show_node $lhs "calm thy unhingedness"
                end_diagnostic
                return
            fi

            local -i i
            for (( i=${#expr[@]} - 1; i >= 2; i-- )); do
                emit_expr ${expr[i]}
                push_reg $EAX
            done

            for (( i=0; i < ${#expr[@]} - 2; i++ )); do
                if (( i < ${#abi_regs[@]} )); then
                    pop_reg ${abi_regs[i]}
                else
                    break
                fi
            done

            call_symbol "${call_target[1]}";;
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
            local -i x=$label_counter
            label_counter+=1

            emit_expr ${expr[1]}
            test_reg_reg $EAX $EAX
            jcc $CC_Z skip$x

            emit_expr ${expr[2]}
            test_reg_reg $EAX $EAX
            label skip$x

            cc_to_reg $CC_NZ $EAX;;
        lor)
            local -i x=$label_counter
            label_counter+=1

            emit_expr ${expr[1]}
            test_reg_reg $EAX $EAX
            jcc $CC_NZ skip$x

            emit_expr ${expr[2]}
            test_reg_reg $EAX $EAX
            label skip$x

            cc_to_reg $CC_NZ $EAX;;
        ternary)
            local -i x=$label_counter
            label_counter+=1

            emit_expr ${expr[1]}
            test_reg_reg $EAX $EAX
            jcc $CC_Z no$x

            emit_expr ${expr[2]}
            jmp end$x

            label no$x
            emit_expr ${expr[3]}
            
            label end$x;;
        *)
            fail "TODO(emit_expr): ${expr[@]}";;
    esac
}
