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
