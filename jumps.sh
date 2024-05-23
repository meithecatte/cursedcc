# Labels are processed per-function.
clear_labels() {
    # Number of bytes from beginning of function to the label's position.
    # Code sizes from before jump sizes get resolved.
    declare -giA label_position=()

    # List of all the labels in declaration order.
    declare -ga  label_order=()

    # The target symbol, relocation type and addend of each relocation.
    declare -ga reloc_target=()

    # Effectively a list of jumps, indexed by how many jumps there are
    # in the function. Sorted by position, by construction.
    #
    # Position of the first byte of the encoded dummy jump (always short).
    # Code sizes from before jump sizes get resolved.
    declare -gia jump_position=()
    # The label that the jump targets.
    declare -ga  jump_target=()
    # The condition code of the jump, if any.
    declare -ga  jump_condition=()
}

reloc() {
    local -i i=${#reloc_target[@]}
    label __reloc$i
    reloc_target+=("$*")
}

# Creates a new label at the current position in the code.
# label name
label() {
    local -i position did_fallthrough=0
    binlength position "$code"
    # Check for a jump that should become fallthrough
    while (( ${#jump_position[@]} )) \
        && [ "${jump_target[-1]}" == "$1" ] \
        && (( jump_position[-1] == position - 2 ))
    do
        local -i i=${#jump_position[@]}-1
        unset jump_position[i]
        unset jump_target[i]
        unset jump_condition[i]
        position=position-2
        code="${code:0:4*position}"
        did_fallthrough=1
        if [ -n "${DEBUG_JUMPS-}" ]; then
            echo "fallthrough at $1"
        fi
    done

    # This handles the case when other labels have been defined between
    # the fall-through jump and the corresponding label, e.g.
    # jmp b; label a; label b
    if (( did_fallthrough )); then
        local -i i
        for (( i=${#label_order[@]}-1; i >= 0; i-- )); do
            local label_name=${label_order[i]}
            if (( label_position[$label_name] > position )); then
                label_position[$label_name]=$position
            else
                break
            fi
        done
    fi

    label_position["$1"]=$position
    label_order+=("$1")
}

# jump target cc
jump() {
    local -i position
    binlength position "$code"

    local -i jump_index="${#jump_position[@]}"
    jump_position[jump_index]=$position
    jump_target[jump_index]="$1"
    jump_condition[jump_index]="${2-}"

    code+="\x0f\x0b" # ud2, also the size of all short jumps
}

# Helper routines for resolve_jumps. Isn't it neat how bash uses dynamic scope?
#
# The algorithm in use here was inspired by https://arxiv.org/abs/0812.4973

# mark_long jump_index
mark_long() {
    local -i i=$1
    if (( !jump_is_long[i] )); then
        jump_is_long[i]=1
        jump_queue+=("$i")
    fi
}

consider_jump() {
    local -i disp=jump_cur_disp[$1]
    if (( disp < -128 || 127 < disp )); then
        mark_long $1
    fi
}

long_encoding_size() {
    if [ -z "${jump_condition[$1]-}" ]; then
        res=5 # e9, then four bytes of offset
    else
        res=6 # 0f, 8x, then four bytes of offset
    fi
}

resolve_jumps() {
    # HACK: It helps a lot with the loops below if we can be sure that after
    # the last label, there are no jumps.
    label __end_of_function

    if [ -n "${DEBUG_JUMPS-}" ]; then
        declare -p label_position
        declare -p jump_position
        declare -p jump_target
    fi

    # A lower bound for the distance the jump will need to cover.
    # If the jump is currently not marked as long, this is the accurate
    # displacement value, assuming the long jumps are exactly the ones that
    # have been dequeued and processed already.
    local -ia jump_cur_disp=()
    local -ia jump_is_long=() jump_queue=()
    local -i i

    for (( i=0; i < ${#jump_position[@]}; i++ )); do
        local -i target=${label_position["${jump_target[i]}"]}
        jump_cur_disp[i]=target-jump_position[i]-2
        consider_jump $i
    done

    while (( ${#jump_queue[@]} )); do
        # Technically not a FIFO queue but this is immaterial
        local -i j=${#jump_queue[-1]}; unset jump_queue[-1]

        # Jumps at lower addresses
        for (( i=j-1; i >= 0 \
            && jump_position[j] - jump_position[i] < 128; i-- ))
        do
            (( jump_is_long[i] )) && continue

            local -i target=${label_position["${jump_target[i]}"]}
            if (( target > jump_position[j] )); then
                long_encoding_size $i
                jump_cur_disp[i]+=res-2
                consider_jump $i
            fi
        done

        # Jumps at higher addresses
        # 
        # (yes, this should be < 128, not <= 128 as they say in the paper.
        # consider the boundary case and it'll be clear to you)
        for (( i=j+1; i < ${#jump_position[@]} \
            && jump_position[i] - jump_position[j] < 128; i++ ))
        do
            (( jump_is_long[i] )) && continue

            local -i target=${label_position["${jump_target[i]}"]}
            if (( target <= jump_position[j] )); then
                long_encoding_size $i
                ! let jump_cur_disp[i]-=res-2
                consider_jump $i
            fi
        done
    done

    # Expand the spacing to fit all the widened jumps.
    local -iA label_actual_position=()
    local -ia jump_actual_position=()
    local -i i=0 adjust=0

    for label in "${label_order[@]}"; do
        local -i position="${label_position["$label"]}"
        while (( i < ${#jump_position[@]} && jump_position[i] < position )); do
            local -i jump_size

            if (( !jump_is_long[i] )); then
                jump_size=2
            else
                long_encoding_size $i; jump_size=$res
            fi

            jump_actual_position[i]=jump_position[i]+adjust

            adjust+=jump_size-2
            i+=1
        done

        label_actual_position["$label"]=position+adjust
    done

    if [ -n "${DEBUG_JUMPS-}" ]; then
        echo "Final adjustment factor: $adjust"
    fi

    # Pre-expansion position.
    local -ia patch_position=()
    local -a  patch_content=()

    for (( i=0; i < ${#jump_position[@]}; i++ )); do
        local -i target="${label_actual_position["${jump_target[i]}"]}"
        local -i position="${jump_actual_position[i]}"
        local patch=""
        local -i disp
        if (( jump_is_long[i] )); then
            if [ -z "${jump_condition[i]-}" ]; then
                patch+="\xe9"
                disp=$((target - position - 5))
            else
                patch+="\x0f"
                p8 patch $((0x80 + jump_condition[i]))
                disp=$((target - position - 6))
            fi

            if (( -128 <= disp && disp < 128 )); then
                internal_error "jump unnecessarily marked as long"
                end_diagnostic
                exit 1
            fi

            p32 patch $disp
        else
            if [ -z "${jump_condition[i]-}" ]; then
                patch+="\xeb"
                disp=$((target - position - 2))
            else
                p8 patch $((0x70 + jump_condition[i]))
                disp=$((target - position - 2))
            fi

            if ! (( -128 <= disp && disp < 128 )); then
                internal_error "jump displacement too long for a short jump"
                end_diagnostic
                exit 1
            fi

            p8 patch $disp
        fi

        patch_position+=("${jump_position[i]}")
        patch_content+=("$patch")
    done

    # Apply the patches.
    local output=""
    local -i inpos=0
    for (( i=0; i < ${#patch_position[@]}; i++ )); do
        local -i pos="${patch_position[i]}"
        output+="${code:4*inpos:4*(pos-inpos)}${patch_content[i]}"
        inpos=pos+2
    done

    output+="${code:4*inpos}"
    code="$output"

    # Adjust the relocations
    for (( i = 0; i < ${#reloc_target[@]}; i++ )); do
        local -i pos="${label_actual_position[__reloc$i]}"
        relocations+=(".text $((function_pos + pos)) ${reloc_target[i]}")
    done
}
