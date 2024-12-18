# NOTE: the label resolver assumes that all bytes in "$code" are encoded
# as four characters (backslash, x, and two hexdigits). So don't get clever
# with octal or \n or whatever else.

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
declare num_abi_regs=${#abi_regs[@]}

CC_E=4
CC_Z=4
CC_NE=5
CC_NZ=5
CC_L=12
CC_GE=13
CC_LE=14
CC_G=15

# rex r b w
# where
# r - the register in the register field (of which the msb should be encoded)
# b - the register in the base field
# w - if non-zero, the instruction uses 64-bit data
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

op_modrm_sym() {
    local op="$1" reg="$2" sym="$3"
    rex $reg 0
    code+="$op"
    p8 code $((5 + 8 * (reg & 7)))
    local -i pos
    binlength pos "$code"
    reloc "$sym" $R_X86_64_PC32 -4
    p32 code 0
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

mov_sym_reg() {
    local sym="$1" src="$2"
    op_modrm_sym "\x89" "$src" "$sym"
}

mov_reg_sym() {
    local dst="$1" sym="$2"
    op_modrm_sym "\x8b" "$dst" "$sym"
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

addq_reg_imm() {
    local dst="$1" imm="$2"
    if (( -128 <= imm && imm <= 127 )); then
        op_modrm_reg "\x83" 0 "$dst" 1
        p8 code "$imm"
    else
        op_modrm_reg "\x81" 0 "$dst" 1
        p32 code "$imm"
    fi
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
    reloc $1 $R_X86_64_PLT32 -4
    p32 code 0
}

emit_global() {
    local decl=(${ast[$1]})
    case ${decl[0]} in
    declare)
        local node
        for node in ${decl[@]:1}; do
            local stc ty var init=''
            unpack $node "declare_var" stc ty var init
            local name
            unpack $var "var" name
            if try_unpack $ty "ty_fun" _ _; then
                if [[ -n "$init" ]]; then
                    error "function declaration includes an initializer"
                    show_node $node "\`$name\` initialized like a variable"
                    end_diagnostic
                fi

                scope_insert $name $node sym $name
            else
                scope_insert $name $node sym $name

                if [[ -n "$init" ]]; then
                    local expr
                    unpack $init "expr" expr
                    eval_expr $expr; local val=$res

                    local offset
                    binlength offset "${sections[.data]}"
                    p32 sections[.data] $val
                    symbol_sections["$name"]=.data
                    symbol_offsets["$name"]=$offset
                else
                    local var_size=4
                    local offset=${sections[.bss]}
                    (( sections[.bss] += var_size ))
                    symbol_sections["$name"]=.bss
                    symbol_offsets["$name"]=$offset
                fi
            fi
        done;;
    nothing) ;;
    *)
        internal_error "finish_declaration returned ${decl[0]}"
        end_diagnostic;;
    esac
}

# AST traversal starts here
# measure_params_stack params
measure_params_stack() {
    local -a params=(${ast[$1]})
    local param_id
    for param_id in "${params[@]:1:num_abi_regs+1}"; do
        local -a param=(${ast[param_id]})
        local -i var_size=4
        stack_used+=$var_size
    done
}

# emit_prologue params
emit_prologue() {
    local -a params=(${ast[$1]})
    local -i i=0
    local param
    # We have already checked for duplicate parameter names
    # in check_param_list. Avoid emitting a duplicate error.
    local suppress_scope_errors=1
    for param in "${params[@]:1}"; do
        local stc ty var=''
        unpack $param "declare_var" stc ty var

        if [ -z "$var" ]; then
            error "missing name for parameter"
            show_node $param "parameter name omitted"
            end_diagnostic
            i+=1; continue
        fi

        local name; unpack $var "var" name
        if (( i < num_abi_regs )); then
            emit_declare_local $param
            emit_var_write $var ${abi_regs[i]}
        else
            scope_insert $name $param rbp $((8 * (i - 6) + 16))
        fi
        i+=1
    done
}

# measure_stack stmt
measure_stack() {
    local -a stmt=(${ast[$1]})
    case ${stmt[0]} in
        compound)
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
            done;;
        expr|return|nothing|goto|continue|break) ;;
        *)  fail "TODO(measure_stack): ${stmt[0]}";;
    esac
}

emit_function() {
    local fname="$1" params="$2" body="$3"

    # Maps goto-labels to the positions at which they were defined
    local -iA user_labels=()

    local -i stack_used=0
    measure_params_stack $params
    measure_stack $body
    local -i stack_max=$stack_used
    stack_used=0

    if (( stack_max % STACK_ALIGNMENT != 0 )); then
        stack_max+=$((16 - stack_max % STACK_ALIGNMENT))
    fi

    clear_labels
    local -i function_pos label_counter=0
    binlength function_pos "${sections[.text]}"
    symbol_sections["$fname"]=.text
    symbol_offsets["$fname"]=$function_pos

    local code=""
    push_reg $RBP
    movq_reg_reg $RBP $RSP

    if (( stack_max )); then
        subq_reg_imm $RSP $stack_max
    fi

    # name -> declaring node (the ones that can be shadowed are not included)
    local -A vars_in_block=()
    # name -> (node, storage); like file_scope - see types.sh
    local -A block_scope=()
    local in_function=1
    emit_prologue $params

    # Variables defined at the top level of the function are part of the same
    # scope as the parameters, and the former are not allowed to shadow
    # the latter. Hence, we need to manually iterate over the body of
    # the function, instead of calling `emit_statement` on the `compound` node.
    #
    # 6.2.1.4. [...] If the declarator or type specifier that declares the
    # identifier appears inside a block or within the list of parameter
    # declarations in a function definition, the identifier has block scope,
    # which terminates at the end of the associated block. [...]
    # If an identifier designates two different entities in the same name
    # space, the scopes might overlap. If so, the scope of one entity (the
    # inner scope) will end strictly before the scope of the other entity (the
    # outer scope).
    local stmts=(${ast[body]})
    if [[ "${stmts[0]}" != "compound" ]]; then
        internal_error "expected function body to be a compound node"
        show_node $body "this is a ${stmts[0]}"
        end_diagnostic
        exit 1
    fi

    local stmt
    for stmt in "${stmts[@]:1}"; do
        emit_statement $stmt
    done

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

# emit_declare_local declare_var
emit_declare_local() {
    local decl="$1"
    local stc ty name; unpack $decl "declare_var" stc ty name _
    local name; unpack $var "var" name
    local -i var_size=4
    local -i stack_offset=$stack_used
    stack_used+=var_size
    scope_insert "$name" "$decl" rbp $((stack_offset - stack_max))

    if (( stack_offset >= stack_max )); then
        internal_error "insufficient stack frame allocated"
        show_node $node "stack offset $stack_offset with stack frame $stack_max"
        end_diagnostic
        exit 1
    fi
}

emit_var_read() {
    local node="$1" reg="$2"
    resolve $node; local decl=$res

    case $storage_type in
    rbp) mov_reg_rbpoff "$reg" "$location";;
    sym) mov_reg_sym "$reg" "$location";;
    *) fail "TODO(emit_var_read): $storage_type";;
    esac
}

emit_var_write() {
    local node="$1" reg="$2"
    local name
    unpack $node "var" name
    local storage_type location
    resolve $node; local decl=$res
    local stc ty var; unpack $decl "declare_var" stc ty var _
    if try_unpack $ty "ty_fun" _ _; then
        error "cannot assign to a function"
        show_node $node "\`$name\` refers to a function"
        show_node $decl "\`$name\` declared here"
        end_diagnostic
        return
    fi

    case $storage_type in
    rbp) mov_rbpoff_reg "$location" "$reg";;
    sym) mov_sym_reg "$location" "$reg";;
    *) fail "TODO(emit_var_write): $storage_type";;
    esac
}

emit_lvalue_write() {
    local lvalue="$1" reg="$2"
    local -a expr=(${ast[lvalue]})
    case ${expr[0]} in
    var)
        emit_var_write "$lvalue" "$reg";;
    *)  error "invalid left-hand side of assignment"
        show_node $lvalue "not an lvalue"
        end_diagnostic;;
    esac
}

emit_statement() {
    local -a stmt=(${ast[$1]})
    case ${stmt[0]} in
        declare)
            local -i i
            local node
            for node in "${stmt[@]:1}"; do
                local stc ty var init=''
                unpack $node "declare_var" stc ty var init
                emit_declare_local $node
                if [ -n "$init" ]; then
                    local value
                    unpack $init "expr" value
                    emit_expr $value
                    emit_var_write $var $EAX
                fi
            done;;
        label)
            label user_${stmt[1]}
            emit_statement ${stmt[2]};;
        compound)
            local -A vars_in_block=() # allow shadowing
            eval "${block_scope[@]@A}"

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
                error "\`break\` can only be used within a loop or switch statement"
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
    local -a expr=(${ast[$1]})
    case ${expr[0]} in
        literal)
            mov_reg_imm $EAX ${expr[1]};;
        var)
            local name="${expr[1]}"
            emit_var_read $1 $EAX;;
        call)
            local lhs="${expr[1]}"
            local callee
            if ! try_unpack $lhs "var" callee; then
                error "indirect calls are not supported"
                show_node $lhs "calm thy unhingedness"
                end_diagnostic
                return
            fi

            local ty
            resolve $lhs; local fundecl=$res
            unpack $fundecl "declare_var" _ ty _ _

            local ty_ret params
            if ! try_unpack $ty "ty_fun" ty_ret params; then
                error "\`$callee\` is not a function"
                show_node $lhs "not a function"
                show_node $fundecl "\`$callee\` declared here"
                end_diagnostic
                return
            fi

            local params=(${ast[params]})

            local num_params=$((${#params[@]} - 1))

            local num_args=$((${#expr[@]} - 2))

            if (( num_args != num_params )); then
                if (( num_args > num_params )); then
                    error "too many arguments for call to \`$callee\`"
                else
                    error "not enough arguments for call to \`$callee\`"
                fi

                local arguments='argument' parameters='parameter'
                (( num_args != 1 )) && arguments+=s
                (( num_params != 1 )) && parameters+=s
                show_node $1 \
                    "$num_args $arguments provided to \`$callee\`"
                show_node $fundecl \
                    "\`$callee\` declared with $num_params $parameters"
                end_diagnostic
            fi

            local -i i num_stack_args=0
            if (( num_args > num_abi_regs )); then
                (( num_stack_args = num_args - num_abi_regs ))
            fi

            local -i arg_space=$((8 * num_stack_args))

            if (( num_stack_args % 2 )); then
                subq_reg_imm $RSP 8
                arg_space+=8
            fi

            for (( i=${#expr[@]} - 1; i >= 2; i-- )); do
                emit_expr ${expr[i]}
                push_reg $EAX
            done

            for (( i=0; i < num_args; i++ )); do
                if (( i < num_abi_regs )); then
                    pop_reg ${abi_regs[i]}
                else
                    break
                fi
            done

            call_symbol "$callee"

            if (( num_args > num_abi_regs )); then
                addq_reg_imm $RSP $arg_space
            fi;;
        assn)
            emit_expr ${expr[2]}
            emit_lvalue_write ${expr[1]} $EAX;;
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
