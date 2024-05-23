declare -i error_count=0
declare -i warning_count=0

RED_BOLD=$'\033[91;1m'
YELLOW_BOLD=$'\033[33;1m'
BLUE_BOLD=$'\033[94;1m'
FG_DEFAULT=$'\033[39m'
RESET=$'\033[0m'

fail() {
    echo "${RED_BOLD}fatal error${FG_DEFAULT}: $@${RESET}" >&2
    exit 1
}

# the color to use when pointing at parts of source code
declare diagnostic_color=

warning() {
    warning_count+=1
    diagnostic_color="${YELLOW_BOLD}"
    echo "${YELLOW_BOLD}warning${FG_DEFAULT}: $@${RESET}" >&2
}

error() {
    error_count+=1
    diagnostic_color="${RED_BOLD}"
    echo "${RED_BOLD}error${FG_DEFAULT}: $@${RESET}" >&2
}

internal_error() {
    error_count+=1
    diagnostic_color="${RED_BOLD}"
    echo "${RED_BOLD}internal compiler error${FG_DEFAULT}: $@${RESET}" >&2
}

# show_line filename:lineno begin len line comment
# (0-indexed)
show_line() {
    local filename=$1
    local IFS=:
    local split=($filename)
    local -i lineno="${split[-1]}"

    local -i begin=$2 len=$3
    local line="$4" comment="$5"

    local -i width=${#lineno}+3
    printf "${BLUE_BOLD}%*s ${RESET}%s:%d\n" \
        $width "-->" "$filename" \
        $((begin + 1)) >&2
    printf "${BLUE_BOLD}%*s\n" $width " | " >&2
    printf "%d | ${RESET}%s\n" $lineno "$line" >&2
    printf "${BLUE_BOLD}%*s${diagnostic_color}%*s" $width " | " $begin "" >&2

    local -i i
    local underline=""
    for (( i=0; i < len; i++ )); do
        underline+="^"
    done
    echo "$underline $comment" >&2
    printf "${BLUE_BOLD}%*s${RESET}\n" $width " | " >&2
}

# show_range line begin end comment
show_range() {
    local -i line=$1 begin=$2 end=$3
    local comment="${4-}"

    local filename="${line_map[line]}"
    show_line "$filename" $begin $((end-begin+1)) "${lines[line]}" "$comment"
}

# show_token token_pos comment
show_token() {
    local -i pos=$1
    local comment="${2-}"
    local -i line="${tokline[pos]}"
    local filename="${line_map[line]}"
    local -i begin="${tokcol[pos]}"
    local -i len="${#tokdata[pos]}"
    show_line "$filename" $begin $len "${lines[line]}" "$comment"
}

# show_node node_id comment
show_node() {
    local pos=(${ast_pos[$1]})
    local comment="${2-}"
    local -i line="${tokline[pos[0]]}"
    local filename="${line_map[line]}"
    local -i begin="${tokcol[pos[0]]}"
    if (( ${tokline[pos[1]]} == line )); then
        local -i end=$((${tokcol[pos[1]]} + ${#tokdata[pos[1]]}))
        local -i len=$((end - begin))
    else
        local -i len=$((${#lines[line]} - begin))
    fi
    show_line "$filename" $begin $len "${lines[line]}" "$comment"
}

# show_eof comment
show_eof() {
    local -i pos=${tokcol[-1]}+${#tokdata[-1]}
    show_range ${tokline[-1]} $pos $pos "${1-}"
}

end_diagnostic() {
    echo >&2
    diagnostic_color=
}
