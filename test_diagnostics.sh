#!/usr/bin/env bash
set -e

TESTDIR="testsuite/tests"
GOLDDIR="diagnostics_tests"

chapter=0
latest_only=0
fail_fast=0
declare -A extra_credit

while (( $# > 0 )); do
    case "$1" in
    --chapter) chapter="$2"; shift 2;;
    --latest-only) latest_only=1; shift;;
    --fail-fast) fail_fast=1; shift;;
    --bitwise) extra_credit["bitwise"]=1; shift;;
    --compound) extra_credit["compound"]=1; shift;;
    --increment) extra_credit["increment"]=1; shift;;
    --goto) extra_credit["goto"]=1; shift;;
    --switch) extra_credit["switch"]=1; shift;;
    --nan) extra_credit["nan"]=1; shift;;
    --union) extra_credit["union"]=1; shift;;
    *)
        echo "Unknown argument: $1" >&2
        exit 1
        ;;
    esac
done

if (( chapter == 0 )); then
    echo "Please specify --chapter" >&2
    exit 1
fi

outfile="$(mktemp ccsh.XXXXXXXXXX.stderr)"
trap "rm -- '$outfile'" EXIT

fail() {
    if (( fail_fast )); then
        exit 1
    fi
}

ask_approve() {
    local ans
    echo -n "Approve new output? (y/n) " >&2
    read ans
    if [[ "$ans" == "y" ]]; then
        mkdir -p "$(dirname "$goldfile")"
        cp "$outfile" "$goldfile"
    else
        fail
    fi
}

check_testcase() {
    local goldfile="$GOLDDIR/${1%.c}.stderr"
    if ./cc.sh -c -o /dev/null $1 2>"$outfile"; then
        echo "Test failed: $1 (exit code 0)" >&2
        fail
    elif [[ -f "$goldfile" ]]; then
        if ! cmp -s "$goldfile" "$outfile"; then
            echo "Test failed: $1" >&2
            echo "Expected output:"
            cat "$goldfile"
            echo "Actual output:"
            cat "$outfile"
            ask_approve
        fi
    else
        echo "Missing golden for $1"
        echo "Actual output:"
        cat "$outfile"
        ask_approve
    fi
}

check_chapter() {
    for name in $TESTDIR/chapter_$1/invalid_*/*.c; do
        if [[ -f "$name" ]]; then
            check_testcase "$name"
        fi
    done
}

if (( latest_only )); then
    check_chapter "$chapter"
else
    for (( i = 1; i <= chapter; i++ )); do
        check_chapter "$i"
    done
fi
