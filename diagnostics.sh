declare -i error_count=0
declare -i warning_count=0

fail() {
    echo "$@" >&2
    exit 1
}

RED_BOLD=$'\033[91;1m'
YELLOW_BOLD=$'\033[33;1m'
BLUE_BOLD=$'\033[94;1m'
FG_DEFAULT=$'\033[39m'
RESET=$'\033[0m'

# the color to use when pointing at parts of source code
declare diagnostic_color

warning() {
    warning_count+=1
    diagnostic_color="${YELLOW_BOLD}"
    echo "${YELLOW_BOLD}warning${FG_DEFAULT}: $@${RESET}"
}

error() {
    error_count+=1
    diagnostic_color="${RED_BOLD}"
    echo "${RED_BOLD}error${FG_DEFAULT}: $@${RESET}"
}

# show_line filename lineno begin len line comment
# (0-indexed)
show_line() {
    local filename=$1
    local -i lineno=$2+1 begin=$3 len=$4
    local line="$5" comment="$6"

    local -i width=${#lineno}+3
    printf "${BLUE_BOLD}%*s ${RESET}%s:%d:%d\n" \
        $width "-->" "$filename" \
        $lineno $((begin + 1))
    printf "${BLUE_BOLD}%*s\n" $width " | "
    printf "%d | ${RESET}%s\n" $lineno "$line"
    printf "${BLUE_BOLD}%*s${diagnostic_color}%*s" $width " | " $begin ""

    local -i i
    local underline=""
    for (( i=0; i < len; i++ )); do
        underline+="^"
    done
    echo "$underline $comment"
    printf "${BLUE_BOLD}%*s${RESET}\n" $width " | "
}

# show_range begin end comment
show_range() {
    local -i begin=$1 end=$2
    local comment=$3

    local before="${src:0:begin}"
    local newlines="${before//[!$'\n']/}"
    local -i lineno=${#newlines}

    local -i curline=0 i lineend=${#src}
    # FIXME: this is slow
    for (( i=0; i < ${#src}; i++)); do
        if [[ "${src:i:1}" == $'\n' ]]; then
            if [[ $curline == $lineno ]]; then
                local -i lineend=i
                break
            fi
            curline+=1
            if [[ $curline == $lineno ]]; then
                local -i linebegin=i+1
            fi
        fi
    done

    local line="${src:linebegin:lineend-linebegin}"
    local -i len=end-begin+1
    show_line "$filename" $lineno $((begin - linebegin)) $len "$line" "$comment"
}

end_diagnostic() {
    echo
    diagnostic_color=
}
