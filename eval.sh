# eval_expr node
eval_expr() {
    local -a expr=(${ast[$1]})
    case "${expr[0]}" in
    literal) res=${expr[1]};;
    *)  fail "TODO(eval_expr): ${expr[*]}";;
    esac
}
