# POSIX shell helper. Source this file; does not execute commands on load.
# The subshell keeps traps, temp files and variables local to the retry.
diskimage_retry() (
    log=$(mktemp) || exit 1
    trap 'rm -f "$log"' EXIT
    trap 'exit 1' HUP INT TERM
    attempt=1
    while :; do
        if "$@" >"$log" 2>&1; then
            cat "$log"
            exit 0
        else
            status=$?
        fi
        cat "$log" >&2
        # Match the specific final DiskImages error, not arbitrary output.
        if [ "$attempt" -ge 3 ] || ! tail -n 1 "$log" | grep -Eq '^hdiutil: (create|verify) failed - (Resource busy|Resource temporarily unavailable)$'; then
            exit "$status"
        fi
        sleep "$((attempt * 3))" || exit 1
        attempt=$((attempt + 1))
    done
)
