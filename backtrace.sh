# show_backtrace n
# where n is the number of frames to skip
show_backtrace() {
    local -i i=${1-0}
    local x
    while x="$(caller $i)"; do
        set -- $x
        echo "  at $3:$1 in $2" >&2
        i+=1
    done
}
