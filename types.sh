# maps name to string with the following space-separated fields:
#  - declaring node (fundecl or declare_var)
#  TODO(global variables):
#  - if declare_var:
#    - storage type ("rbp", ".data" or ".bss")
#    - offset
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
    local ty1 ty2
    unpack $1 declare_var ty1 _ _
    unpack $2 declare_var ty2 _ _
    local name=$3

    local ret1 ret2 params1 params2
    if try_unpack $ty1 ty_fun ret1 params1 &&
        try_unpack $ty2 ty_fun ret2 params2
    then
        local params1=(${ast[params1]})
        local params2=(${ast[params2]})
        local count1=$((${#params1[@]} - 1))
        local count2=$((${#params2[@]} - 1))
        # TODO: do more exhaustive checks once we support more types
        if (( count1 != count2 )); then
            error "conflicting declarations of \`$name\`"
            show_node $1 "\`$name\` defined here with $count1 parameters"
            show_node $2 "\`$name\` redefined with $count2 parameters"
            end_diagnostic
            return # don't emit further diagnostics in scope_insert
        fi

        return
    else
        (( !in_function )) && echo "TODO: tentative definitions and shit"
        return 1
    fi
}

# check_param_list param_nodes...
# Uses $begin from the outer scope to call mknode
# (this is to turn f(void) into something that logically has no parameters,
# despite the fact that there is one syntactic entry in the list)
check_param_list() {
    local -A names_used=() # points to the 'param' nodes
    for param in "$@"; do
        local ty var=''
        unpack $param declare_var ty var

        if try_unpack $ty ty_void; then
            if [ -n "$var" ]; then
                error "invalid type for parameter"
                show_node $param "parameter cannot have type \`void\`"
                end_diagnostic
                continue
            elif (( $# != 1 )); then
                error "\`void\` must be the only parameter"
                show_node $param "\`void\` must be the only parameter"
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
                show_node $param "\`$name\` redefined here"
                end_diagnostic
            else
                names_used["$name"]=$param
            fi
        fi
    done

    mknode "params ${param_list[*]}" $begin
}

# unfuck_declarator node base_type
# returns ty, var
#
# Turns the raw almost-CST of a declarator into an actual type and variable,
# by inverting the entire damn structure.
unfuck_declarator() {
    local decl=(${ast[$1]}) base_type=$2 pos="${ast_pos[$1]}"
    case "${decl[0]}" in
    var) # base case - 6.7.6p5
        ty=$base_type
        var=$1;;
    decl_fun) # 6.7.6.3 Function declarators
        local inner="${decl[1]}"
        local params="${decl[2]}"

        # 6.7.6.3p1 "A function declarator shall not specify a return type
        # that is a function type or an array type."
        local other_params
        if try_unpack $base_type ty_fun _ other_params; then
            error "cannot return function from function"
            show_node $1 "function declared here"
            show_node $other_params "return type is a function type"
            end_diagnostic
            return 1
        fi
        mknode "ty_fun $base_type $params" $pos
        unfuck_declarator $inner $res;;
    *)
        fail "TODO(unfuck_declarator): ${decl[*]}";;
    esac
}
