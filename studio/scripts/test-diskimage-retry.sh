#!/bin/sh
set -eu
. "$(dirname "$0")/diskimage-retry.sh"
temp=$(mktemp -d)
trap 'rm -rf "$temp"' EXIT
# No real sleeps or hdiutil operations during tests.
sleep() { :; }
mock() {
    n=$(cat "$temp/count")
    n=$((n+1))
    printf '%s\n' "$n" > "$temp/count"
    case "$mode" in
        transient)
            [ "$n" -ge 2 ] && return 0
            echo 'hdiutil: verify failed - Resource temporarily unavailable' >&2 ;;
        busy)
            [ "$n" -ge 3 ] && return 0
            echo 'hdiutil: create failed - Resource busy' >&2 ;;
        permanent) echo 'hdiutil: verify failed - image checksum is invalid' >&2 ;;
        misleading) printf '%s\n' 'hdiutil: verify failed - Resource busy' 'checksum mismatch' >&2 ;;
        exhausted) echo 'hdiutil: verify failed - Resource temporarily unavailable' >&2 ;;
    esac
    return 7
}
check() {
    mode=$1
    expected_status=$2
    expected_attempts=$3
    echo 0 > "$temp/count"
    actual=0
    diskimage_retry mock || actual=$?
    [ "$actual" -eq "$expected_status" ]
    [ "$(cat "$temp/count")" -eq "$expected_attempts" ]
}
check transient 0 2
check busy 0 3
check permanent 7 1
check misleading 7 1
check exhausted 7 3
echo 'Disk image retry policy: 5 cases passed.'
