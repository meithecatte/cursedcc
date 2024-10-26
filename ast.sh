declare -a ast=() ast_pos=()

# mknode node begin
mknode() {
    local end=${3-$((pos - 1))}
    local begin=${2-$end}
    res=${#ast[@]}
    ast+=("$1")
    ast_pos+=("$begin $end")
}

# try_unpack node expected_type params...
try_unpack() {
    local _node=$1 _expected=$2 _part
    if ! [[ "$_node" =~ ^[0-9]*$ && -n "${ast[_node]-}" ]]; then
        internal_error "invalid index $_node for try_unpack"
        exit 1
    fi

    local _parts=(${ast[_node]})
    if [[ "$_expected" != "${_parts[0]}" ]]; then
        return 1
    fi

    shift 2
    if (( ${#_parts[@]} - 1 > $# )); then
        return 1
    fi

    for _part in "${_parts[@]:1}"; do
        local -n _ref=$1; shift 1
        _ref="$_part"
    done
}

# unpack node expected_type params...
unpack() {
    if ! try_unpack "$@"; then
        local _parts=(${ast[$1]})
        internal_error "expected node of type $2, got ${_parts[0]}"
        show_node $1 "${_parts[*]}"
        end_diagnostic
        exit 1
    fi
}

dump_ast_as() {
    if [ -n "${DEBUG_AST-}" ]; then
        echo "$2:"
        local level=0
        dump_ast $1
    fi
}

dump_ast() {
    local level="$(( level + 1 ))"
    for node in "$@"; do
        if (( node < 0 )); then continue; fi

        printf "%*s %d: %s\n" $((2 * level)) "+" $node "${ast[node]}"

        local parts=(${ast[node]})
        set -- "${parts[@]}"
        case "${parts[0]}" in
        label)
            dump_ast ${parts[2]} ;;
        literal|var) ;;
        *)
            dump_ast ${parts[@]:1} ;;
        esac
    done
}
