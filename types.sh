# maps name to fundecl or declare_var, with location being the declaration
declare -A file_scope=()
declare in_function=0

# resolve var
# output in $res
resolve() {
    local var=(${ast[$1]})
    local name="${var[1]}"
    if (( in_function )) && [[ -n "${block_scope["$name"]-}" ]]; then
        res="${block_scope["$name"]}"
    elif [[ -n "${file_scope["$name"]-}" ]]; then
        res="${file_scope["$name"]}"
    else
        error "\`$name\` undeclared"
        show_node $var "\`$name\`"
    fi
}

# scope_insert name node
scope_insert() {
    local name="$1" node="$2"
    if (( in_function )); then
        # TODO: merge declarations if allowed
        if [ -n "${vars_in_block[$name]-}" ] && \
            ! check_redeclaration "${block_scope[$name]}" "$node" "$name"
        then
            error "redefinition of \`$name\`"
            show_node ${vars_in_block[$name]} "\`$name\` first defined here"
            show_node $node "\`$name\` redefined here"
            end_diagnostic
            return 1
        fi

        vars_in_block[$name]=$node
        block_scope[$name]=$node
    else
        if [ -n "${file_scope[$name]-}" ] && \
            ! check_redeclaration "${file_scope[$name]}" "$node" "$name"
        then
            error "redefinition of \`$name\`"
            show_node ${file_scope[$name]} "\`$name\` first defined here"
            show_node $node "\`$name\` redefined here"
            end_diagnostic
            return 1
        fi

        file_scope[$name]=$node
    fi
}

# check_redeclaration prev_node cur_node name
check_redeclaration() {
    local previous=(${ast[$1]}) current=(${ast[$2]}) name="$3"
    case $previous,$current in
    fundecl,fundecl)
        local previous_params=(${ast[previous[2]]})
        local current_params=(${ast[current[2]]})
        local previous_count=$((${#previous_params[@]} - 1))
        local current_count=$((${#current_params[@]} - 1))
        # TODO: do more exhaustive checks once we support more types
        if (( previous_count != current_count )); then
            error "conflicting declarations of \`$name\`"
            show_node $1 "\`$name\` defined here with $previous_count parameters"
            show_node $2 "\`$name\` redefined with $current_count parameters"
            end_diagnostic
            return # don't emit further diagnostics in scope_insert
        fi

        return;;
    declare_var,declare_var)
        (( !in_function )) && echo "TODO: tentative definitions and shit"
        return 1;;
    *) return 1;;
    esac
}

# check_param_list param_nodes...
# Uses $begin from the outer scope to call mknode
# (this is to turn f(void) into something that logically has no parameters,
# despite the fact that there is one syntactic entry in the list)
check_param_list() {
    local -A names_used=() # points to the 'param' nodes
    for param_id in "$@"; do
        local -a param=(${ast[param_id]})
        local ty="${param[1]}"
        local var="${param[2]-}"

        if [ "$ty" == void ]; then
            if [ -n "$var" ]; then
                error "invalid type for parameter"
                show_node $param_id "parameter cannot have type \`void\`"
                end_diagnostic
                continue
            elif (( $# != 1 )); then
                error "\`void\` must be the only parameter"
                show_node $param_id "\`void\` must be the only parameter"
                end_diagnostic
                continue
            else
                # The only parameter is void without a name
                mknode "params" $begin
                return
            fi
        fi

        if [ -n "$var" ]; then
            local name="${ast[var]#var }"
            if [ -n "${names_used["$name"]-}" ]; then
                error "redefinition of parameter \`$name\`"
                show_node ${names_used["$name"]} "\`$name\` first defined here"
                show_node $param_id "\`$name\` redefined here"
                end_diagnostic
            else
                names_used["$name"]=$param_id
            fi
        fi
    done

    mknode "params ${param_list[*]}" $begin
}
