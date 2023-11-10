# Labels are processed per-function.
clear_labels() {
    # Number of bytes from beginning of function to the label's position.
    # Code sizes from before jump sizes get resolved.
    declare -giA label_position=()

    # List of all the labels in declaration order.
    declare -ga  label_order=()

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

# Creates a new label at the current position in the code.
# label name
label() {
    # TODO: optimize fallthrough here
    local -i position
    binlength position "$code"
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

resolve_jumps() {
    # HACK: It helps a lot with the loops below if we can be sure that after
    # the last label, there are no jumps.
    label __end_of_function

    local -ia jump_is_long=()
    local -i i

    # For now, conservatively assume all jumps need the long encoding.
    for (( i=0; i <= ${#jump_position[@]}; i++ )); do
        jump_is_long[i]=1
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
            elif [ -z "${jump_condition[i]-}" ]; then
                jump_size=5 # e9, then four bytes of offset
            else
                jump_size=6 # 0f, 8x, then four bytes of offset
            fi

            jump_actual_position[i]=jump_position[i]+adjust

            adjust+=jump_size-2
            i+=1
        done

        label_actual_position["$label"]=position+adjust
    done

    # Pre-expansion position.
    local -ia patch_position=()
    local -a  patch_content=()

    for (( i=0; i < ${#jump_position[@]}; i++ )); do
        local -i target="${label_actual_position["${jump_target[i]}"]}"
        local -i position="${jump_actual_position[i]}"
        local patch=""
        if (( jump_is_long[i] )); then
            if [ -z "${jump_condition[i]-}" ]; then
                patch+="\xe9"
                p32 patch $((target - position - 5))
            else
                patch+="\x0f"
                p8 patch $((0x80 + jump_condition[i]))
                p32 patch $((target - position - 6))
            fi
        else
            if [ -z "${jump_condition[-]-}" ]; then
                patch+="\xeb"
                p8 patch $((target - position - 2))
            else
                p8 patch $((0x70 + jump_condition[i]))
                p8 patch $((target - position - 2))
            fi
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
}
